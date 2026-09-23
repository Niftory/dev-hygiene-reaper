#!/usr/bin/env bash
#
# reap-idle-daemons.sh — reclaim agent-browser daemons that have gone stale.
#
# WHY: the ~/.zshrc agent-browser wrapper deliberately gives the shared/default
# daemon NO idle timeout (to protect long-lived logged-in sessions like
# derive/siftgpt). The cost is that one daemon per session accumulates and
# never dies — observed as 6 daemons aged 1-9 DAYS pinning system load into
# the 70s on a 14-core box, wedging git/find/pnpm/typecheck. This runs hourly
# (launchd) and closes ONLY daemons that are BOTH old AND idle, so an actively-
# used session is never touched.
#
# IDLE = low CPU RATE, not zero. An abandoned daemon still emits a tiny CPU
# heartbeat every few seconds (~2-3 CPU-sec/hour observed), so exact-equality
# would never flag it. Instead: a daemon is "idle this run" if it used less
# than IDLE_CPU_SEC of CPU since the previous run. A driven browser session
# uses far more; a wedged one uses thousands — both cleanly excluded.
#
# SAFETY — this box is shared by multiple concurrent Claude Code sessions:
#   * Targets ONLY processes matching `agent-browser-darwin` (the daemon
#     binary) and `agent-browser-chrome-<uuid>` (its Chrome user-data-dir).
#     The daemon guard checks the executable basename, not the full path.
#     Worktrees under `.claude/` are common and must not look like Claude
#     processes. A hard guard still refuses any executable outside the
#     agent-browser allowlist.
#   * Never matches by port. Never touches the reaper's own process tree.
#   * A daemon is reaped only after IDLE_RUNS_TO_REAP consecutive runs under
#     the CPU-rate threshold AND an age over AGE_MIN_SEC — activity resets the
#     idle streak, so an in-use session survives indefinitely.
#   * First sighting (no prior state) never reaps; it only records a baseline.
#   * --dry-run reports without killing AND without perturbing the streak state.
#
# Usage:
#   reap-idle-daemons.sh            # reap idle daemons, log to stdout
#   reap-idle-daemons.sh --dry-run  # report what WOULD be reaped, change nothing
set -euo pipefail

AGE_MIN_SEC="${AGENT_BROWSER_REAP_AGE_MIN_SEC:-7200}"    # 2h: never reap younger
IDLE_CPU_SEC="${AGENT_BROWSER_REAP_IDLE_CPU_SEC:-15}"    # <15 CPU-sec since last run = idle
IDLE_RUNS_TO_REAP="${AGENT_BROWSER_REAP_IDLE_RUNS:-2}"   # 2 idle runs in a row ≈ 2 idle hours
STATE_DIR="$HOME/.agent-browser"
STATE_FILE="$STATE_DIR/reaper-state"
NEW_STATE="$STATE_DIR/reaper-state.new"

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

# cputime (MIN:SEC.frac, MIN may exceed 59, e.g. 1103:04.45) -> integer seconds.
cputime_to_sec() {
  awk -v t="$1" 'BEGIN {
    n = split(t, a, ":")
    if (n == 2) { printf "%d", a[1]*60 + a[2] }
    else if (n == 3) { printf "%d", a[1]*3600 + a[2]*60 + a[3] }
    else { print 0 }
  }'
}

# Previous "cpu_sec idle_runs" for a pid from the last run's state.
prev_for() { awk -v p="$1" '$1==p {print $2, $3}' "$STATE_FILE" 2>/dev/null; }

# `ps` command output starts with argv[0]. Match only that executable, because
# an agent-browser binary can live inside a `.claude/worktrees/...` path.
process_basename() {
  local executable
  executable="$(printf '%s\n' "$1" | awk 'NF {print $1; exit}')"
  printf '%s\n' "${executable##*/}"
}

is_agent_browser_daemon() {
  case "$(process_basename "$1")" in
    agent-browser-darwin|agent-browser-darwin-arm64|agent-browser-darwin-x64) return 0 ;;
    *) return 1 ;;
  esac
}

is_claude_executable() {
  case "$(process_basename "$1")" in
    Claude|claude|claude-code) return 0 ;;
    *) return 1 ;;
  esac
}

reaped=0 kept=0
DAEMONS="$(pgrep -f 'agent-browser-darwin' 2>/dev/null || true)"

for pid in $DAEMONS; do
  read -r etime cputime < <(ps -o etime=,cputime= -p "$pid" 2>/dev/null | awk '{print $1, $2}')
  [ -z "${cputime:-}" ] && continue   # vanished between pgrep and ps

  # HARD GUARD: command MUST be an agent-browser daemon and MUST NOT be claude.
  cmd="$(ps -ww -o command= -p "$pid" 2>/dev/null || true)"
  if ! is_agent_browser_daemon "$cmd"; then
    log "SKIP $pid — executable is not an agent-browser daemon"
    continue
  fi
  if is_claude_executable "$cmd"; then
    log "SKIP $pid — executable is Claude"
    continue
  fi

  age_sec="$(etime_to_sec "$etime")"
  cpu_sec="$(cputime_to_sec "$cputime")"
  read -r prev_cpu prev_idle <<<"$(prev_for "$pid")"

  # Idle streak: CPU used since last run under the rate threshold = idle.
  idle_runs=0
  if [ -n "${prev_cpu:-}" ]; then
    delta=$(( cpu_sec - prev_cpu ))
    [ "$delta" -lt 0 ] && delta=0
    if [ "$delta" -lt "$IDLE_CPU_SEC" ]; then
      idle_runs=$(( ${prev_idle:-0} + 1 ))
    fi
  fi

  if [ "$age_sec" -ge "$AGE_MIN_SEC" ] && [ "$idle_runs" -ge "$IDLE_RUNS_TO_REAP" ]; then
    child="$(pgrep -P "$pid" 2>/dev/null | head -1 || true)"
    uuid=""
    if [ -n "$child" ]; then
      uuid="$(ps -ww -o command= -p "$child" 2>/dev/null | grep -oE 'agent-browser-chrome-[0-9a-f-]{36}' | head -1 || true)"
    fi
    if [ "$DRY_RUN" = 1 ]; then
      log "WOULD REAP daemon $pid (age ${age_sec}s, idle ${idle_runs} runs)${uuid:+, chrome $uuid}"
      # Dry-run must not perturb real streak state: preserve the prior line.
      echo "$pid $cpu_sec ${prev_idle:-0}" >> "$NEW_STATE"
    else
      [ -n "$uuid" ] && pkill -f "$uuid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      log "REAPED daemon $pid (age ${age_sec}s, idle ${idle_runs} runs)${uuid:+, chrome $uuid}"
    fi
    reaped=$(( reaped + 1 ))
  else
    echo "$pid $cpu_sec $idle_runs" >> "$NEW_STATE"
    kept=$(( kept + 1 ))
  fi
done

mv -f "$NEW_STATE" "$STATE_FILE"

# Orphan sweep: a daemon that died by crash/OOM (not our reap) reparents its
# Chrome to launchd (PPID 1), where it lingers with no daemon to shut it down —
# almost certainly how the original 42-process pileup formed. An agent-browser
# Chrome with PPID 1 is unambiguously abandoned (no age/idle test needed): its
# managing daemon is already gone. Match by the unique user-data-dir string, so
# a real Google Chrome window (no agent-browser-chrome- dir) is never touched.
orphans=0
for cpid in $(pgrep -f 'agent-browser-chrome-' 2>/dev/null || true); do
  [ "$(ps -o ppid= -p "$cpid" 2>/dev/null | tr -d ' ')" = "1" ] || continue
  ccmd="$(ps -ww -o command= -p "$cpid" 2>/dev/null || true)"
  case "$ccmd" in *agent-browser-chrome-*) ;; *) continue;; esac   # belt-and-suspenders
  is_claude_executable "$ccmd" && continue
  if [ "$DRY_RUN" = 1 ]; then
    log "WOULD SWEEP orphan chrome $cpid (PPID 1)"
  else
    kill "$cpid" 2>/dev/null || true
    log "SWEPT orphan chrome $cpid (PPID 1)"
  fi
  orphans=$(( orphans + 1 ))
done

suffix=""; [ "$DRY_RUN" = 1 ] && suffix=" (dry-run)"
log "done: ${reaped} reaped, ${orphans} orphans swept, ${kept} kept${suffix}"
