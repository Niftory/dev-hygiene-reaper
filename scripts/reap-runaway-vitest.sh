#!/usr/bin/env bash
#
# reap-runaway-vitest.sh — release machine resources from disposable Vitest runs.
#
# A normal `vitest run` on this machine finishes in seconds or low minutes. A
# previous hung worker ran for 27+ hours and held a CPU core. Tests are free to
# drop here, so launchd gives a run ten minutes. It ends an old run at the first
# sighting, or ends it immediately when one worker is too large or swap is high.
#
# Safety:
#   * Targets only Vitest workers and Vitest runner commands. It cannot match a
#     Vite or Next dev server.
#   * The parent walk accepts only Vitest and its pnpm/npm/yarn/tsx wrappers.
#     It stops before a shell, a ChatGPT/Codex/Claude host, or PID 1.
#   * Signals TERM first, then KILL after one second for any survivor.
#   * --dry-run reports targets and leaves both processes and state unchanged.
#
# Usage:
#   reap-runaway-vitest.sh
#   reap-runaway-vitest.sh --dry-run
set -uo pipefail

AGE_MIN_SEC="${VITEST_REAP_AGE_MIN_SEC:-600}"            # 10 minutes
CONFIRM_RUNS_TO_REAP="${VITEST_REAP_CONFIRM_RUNS:-1}"    # first over-age sighting
RSS_MAX_MB="${VITEST_REAP_RSS_MAX_MB:-2048}"             # a single worker above 2GiB
SWAP_MAX_MB="${VITEST_REAP_SWAP_MAX_MB:-4096}"           # system under serious pressure
STATE_DIR="$HOME/.dev-hygiene"
STATE_FILE="$STATE_DIR/vitest-reaper-state"
NEW_STATE="$STATE_DIR/vitest-reaper-state.new"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

mkdir -p "$STATE_DIR"
: > "$NEW_STATE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# etime ([[DD-]HH:]MM:SS) -> integer seconds. Portable, no GNU date.
etime_to_sec() {
  local e="$1" days=0 rest hh=0 mm ss
  case "$e" in *-*) days="${e%%-*}"; rest="${e#*-}";; *) rest="$e";; esac
  local IFS=:
  # shellcheck disable=SC2086
  set -- $rest
  case $# in
    3) hh="$1"; mm="$2"; ss="$3";;
    2) mm="$1"; ss="$2";;
    *) echo 0; return;;
  esac
  echo $(( 10#$days*86400 + 10#$hh*3600 + 10#$mm*60 + 10#$ss ))
}

prev_confirm_for() { awk -v p="$1" '$1==p {print $2}' "$STATE_FILE" 2>/dev/null; }

# Vitest's runner and workers are Node processes. Requiring the executable
# shape prevents a shell or search command that merely mentions a Vitest path
# from ever becoming a candidate.
is_node_command() {
  case "$1" in
    node\ *|*/node\ *) return 0 ;;
    *) return 1 ;;
  esac
}

vitest_kind() {
  is_node_command "$1" || return 1
  case "$1" in
    *vitest/dist/workers/*) echo "worker" ;;
    */vitest/vitest.mjs*|*/vitest/dist/cli.*|*/vitest/dist/cli/*) echo "runner" ;;
    *) return 1 ;;
  esac
}

# The allowed parents are the test run itself, never its terminal or agent.
is_test_wrapper() {
  case "$1" in
    *vitest/dist/workers/*|*/vitest/vitest.mjs*|*/vitest/dist/cli.*|*/vitest/dist/cli/*|\
    *pnpm*|*npm*|*yarn*|*scripts/test/run-integration.ts*|*tsx*run-integration*) return 0 ;;
    *) return 1 ;;
  esac
}

# Read whole MiB from macOS's `vm.swapusage`. An unreadable value simply turns
# off the swap trigger for this pass; age and RSS limits still apply.
swap_used_mb() {
  /usr/sbin/sysctl -n vm.swapusage 2>/dev/null | /usr/bin/awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "used" && $(i + 1) == "=") {
          value = $(i + 2)
          unit = substr(value, length(value), 1)
          gsub(/[A-Za-z]/, "", value)
          if (unit == "G") print int(value * 1024)
          else if (unit == "M") print int(value)
          exit
        }
      }
    }
  '
}

# Include only the test process and its recognized test wrappers. It has no
# route to the ChatGPT/Codex/Claude process that requested the test.
chain_to_kill() {
  local cur="$1" hops=0 ppid pcmd
  echo "$cur"
  while [ "$hops" -lt 6 ]; do
    hops=$(( hops + 1 ))
    ppid="$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')"
    [ -n "$ppid" ] && [ "$ppid" != "1" ] || break
    pcmd="$(ps -o command= -p "$ppid" 2>/dev/null || true)"
    is_test_wrapper "$pcmd" || break
    echo "$ppid"
    cur="$ppid"
  done
}

add_pid_once() {
  case " $REAP_PIDS " in
    *" $1 "*) ;;
    *) REAP_PIDS="$REAP_PIDS $1" ;;
  esac
}

swap_mb="$(swap_used_mb || true)"
swap_stressed=0
case "$swap_mb" in
  ''|*[!0-9]*) log "swap usage unavailable — age/RSS limits stay active" ;;
  *)
    if [ "$swap_mb" -ge "$SWAP_MAX_MB" ]; then
      swap_stressed=1
      log "swap ${swap_mb}MiB >= ${SWAP_MAX_MB}MiB — dropping active Vitest runs"
    fi
    ;;
esac

reaped=0
kept=0
REAP_PIDS=""
while read -r pid etime rss_kb cmd; do
  [ -n "${pid:-}" ] || continue
  kind="$(vitest_kind "$cmd" || true)"
  [ -n "$kind" ] || continue

  age_sec="$(etime_to_sec "$etime")"
  case "$rss_kb" in ''|*[!0-9]*) rss_mb=0 ;; *) rss_mb=$(( rss_kb / 1024 )) ;; esac

  reason=""
  if [ "$swap_stressed" = 1 ]; then
    reason="swap pressure (${swap_mb}MiB)"
  elif [ "$rss_mb" -ge "$RSS_MAX_MB" ]; then
    reason="RSS ${rss_mb}MiB >= ${RSS_MAX_MB}MiB"
  elif [ "$age_sec" -lt "$AGE_MIN_SEC" ]; then
    kept=$(( kept + 1 ))
    continue
  else
    prev_confirm="$(prev_confirm_for "$pid")"
    confirm=$(( ${prev_confirm:-0} + 1 ))
    if [ "$confirm" -lt "$CONFIRM_RUNS_TO_REAP" ]; then
      echo "$pid $confirm" >> "$NEW_STATE"
      kept=$(( kept + 1 ))
      log "SEEN Vitest $kind $pid past age bound (age ${age_sec}s), confirm ${confirm}/${CONFIRM_RUNS_TO_REAP} — not yet reaping"
      continue
    fi
    reason="age ${age_sec}s >= ${AGE_MIN_SEC}s"
  fi

  chain="$(chain_to_kill "$pid")"
  for cpid in $chain; do add_pid_once "$cpid"; done
  action="REAPED"
  [ "$DRY_RUN" = 1 ] && action="WOULD REAP"
  log "$action Vitest $kind $pid ($reason) + test chain: $chain"
  reaped=$(( reaped + 1 ))
done < <(ps -axo pid=,etime=,rss=,command=)

if [ "$DRY_RUN" = 1 ]; then
  rm -f "$NEW_STATE"
elif [ -n "$REAP_PIDS" ]; then
  for cpid in $REAP_PIDS; do kill -TERM "$cpid" 2>/dev/null || true; done
  sleep 1
  forced=0
  for cpid in $REAP_PIDS; do
    if kill -0 "$cpid" 2>/dev/null; then
      kill -KILL "$cpid" 2>/dev/null || true
      forced=$(( forced + 1 ))
    fi
  done
  mv -f "$NEW_STATE" "$STATE_FILE"
  log "terminated ${reaped} Vitest candidates (${forced} required KILL)"
else
  mv -f "$NEW_STATE" "$STATE_FILE"
fi

suffix=""; [ "$DRY_RUN" = 1 ] && suffix=" (dry-run)"
log "done: ${reaped} reaped, ${kept} kept${suffix}"
