#!/usr/bin/env bash
#
# reap-next-jobs.sh — release memory from local Next.js process trees.
#
# This runs only through ~/.dev-hygiene/reaper.sh, the one LaunchAgent that
# also handles orphaned ChatGPT helpers and browser/test cleanup. A Next dev
# server is safe to restart. It must therefore yield before a foreground app
# when either condition is true:
#
#   * macOS reports at least 4GiB of swap in use; or
#   * one Next process tree uses at least 4GiB resident memory.
#
# Both limits are configurable. They are high enough to avoid a normal compile,
# but low enough to recover the desktop before it becomes unusable. The reaper
# targets only Next's known executable paths/process titles, recursively
# includes their children, and never walks up to a shell, pnpm, or an agent.
#
# Usage:
#   reap-next-jobs.sh
#   reap-next-jobs.sh --dry-run
set -uo pipefail

SWAP_MAX_MB="${NEXT_REAP_SWAP_MAX_MB:-4096}"
TREE_RSS_MAX_MB="${NEXT_REAP_TREE_RSS_MAX_MB:-4096}"
GRACE_SEC="${NEXT_REAP_GRACE_SEC:-2}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

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

# Process titles vary by Next and Node version. These patterns cover the
# executable path used by package managers and the next-server title Next sets
# for its actual server process. A plain `next` word is never enough to match.
is_next_command() {
  case "$1" in
    */node_modules/next/*|*/node_modules/.bin/next*|*/node_modules/.bin/../next/*|\
    next-server\ *|*' next-server '*|\
    *next-dev-server*|*next-start-server*) return 0 ;;
    *) return 1 ;;
  esac
}

tree_pids() {
  local pid="$1" child
  echo "$pid"
  for child in $(/usr/bin/pgrep -P "$pid" 2>/dev/null || true); do
    tree_pids "$child"
  done
}

tree_rss_mb() {
  local pid="$1" child rss_kb=0 rss
  for child in $(tree_pids "$pid"); do
    rss="$(/bin/ps -o rss= -p "$child" 2>/dev/null | tr -d ' ')"
    case "$rss" in ''|*[!0-9]*) continue ;; esac
    rss_kb=$(( rss_kb + rss ))
  done
  echo $(( rss_kb / 1024 ))
}

has_pid() {
  case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

add_tree_once() {
  local pid="$1" child
  has_pid "$REAP_PIDS" "$pid" && return
  REAP_PIDS="$REAP_PIDS $pid"
  for child in $(/usr/bin/pgrep -P "$pid" 2>/dev/null || true); do
    add_tree_once "$child"
  done
}

swap_mb="$(swap_used_mb || true)"
swap_stressed=0
case "$swap_mb" in
  ''|*[!0-9]*) log "swap usage unavailable — checking only per-tree RSS" ;;
  *)
    if [ "$swap_mb" -ge "$SWAP_MAX_MB" ]; then
      swap_stressed=1
      log "swap ${swap_mb}MiB >= ${SWAP_MAX_MB}MiB — Next yields first"
    fi
    ;;
esac

NEXT_PIDS=""
while read -r pid ppid cmd; do
  [ -n "${pid:-}" ] || continue
  is_next_command "$cmd" || continue
  NEXT_PIDS="$NEXT_PIDS $pid"
done < <(ps -axo pid=,ppid=,command=)

[ -n "$NEXT_PIDS" ] || {
  log "done: no local Next processes"
  exit 0
}

# Keep only the highest matching process in each Next tree. Its descendants
# are gathered below, so one reaping action shuts down the whole dev server.
ROOTS=""
roots_count=0
for pid in $NEXT_PIDS; do
  ppid="$(/bin/ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -n "$ppid" ] && has_pid "$NEXT_PIDS" "$ppid" && continue
  ROOTS="$ROOTS $pid"
  roots_count=$(( roots_count + 1 ))
done

REAP_PIDS=""
reaped=0
for pid in $ROOTS; do
  rss_mb="$(tree_rss_mb "$pid")"
  reason=""
  if [ "$swap_stressed" = 1 ]; then
    reason="swap pressure (${swap_mb}MiB)"
  elif [ "$rss_mb" -ge "$TREE_RSS_MAX_MB" ]; then
    reason="tree RSS ${rss_mb}MiB >= ${TREE_RSS_MAX_MB}MiB"
  else
    continue
  fi

  action="REAPED"
  [ "$DRY_RUN" = 1 ] && action="WOULD REAP"
  log "$action Next root $pid ($reason)"
  add_tree_once "$pid"
  reaped=$(( reaped + 1 ))
done

if [ "$reaped" -eq 0 ]; then
  log "done: ${roots_count} Next roots below thresholds"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  log "done: would reap ${reaped} Next roots (${REAP_PIDS# })"
  exit 0
fi

for pid in $REAP_PIDS; do kill -TERM "$pid" 2>/dev/null || true; done
sleep "$GRACE_SEC"
forced=0
for pid in $REAP_PIDS; do
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    forced=$(( forced + 1 ))
  fi
done

log "done: reaped ${reaped} Next roots (${forced} required KILL)"
