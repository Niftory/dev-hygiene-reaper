#!/usr/bin/env bash
# Reap abandoned headless Chrome and runaway agent-browser sessions.
# This runs every five minutes through reaper.sh.
set -euo pipefail

CPU_LIMIT="${CHROME_REAP_CPU_PERCENT:-80}"
RAM_LIMIT="${CHROME_REAP_RAM_PERCENT:-80}"
PROFILE_RSS_LIMIT_MB="${CHROME_REAP_PROFILE_RSS_MB:-512}"
MIN_AGE_SEC="${CHROME_REAP_MIN_AGE_SEC:-120}"
CHROME_RE='[Cc]hrom(e|ium)'
DAEMON_RE='agent-browser'
NEVER_KILL_RE='(^|[ /])(node|claude|pnpm|npm|tsx|bash|zsh|sh|ps|grep)([ /]|$)'
DRY_RUN=0

if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
elif [ "$#" -gt 0 ]; then
  echo "usage: $0 [--dry-run]" >&2
  exit 2
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

etime_to_sec() {
  printf '%s' "$1" | awk -F'[-:]' '{
    n = NF; s = $n; m = (n >= 2) ? $(n-1) : 0
    h = (n >= 3) ? $(n-2) : 0; d = (n >= 4) ? $(n-3) : 0
    print d*86400 + h*3600 + m*60 + s
  }'
}

ram_used_percent() {
  if command -v memory_pressure >/dev/null 2>&1; then
    memory_pressure -Q 2>/dev/null |
      awk '/System-wide memory free percentage:/ {
        gsub("%", "", $NF); print 100 - $NF; exit
      }'
  elif [ -r /proc/meminfo ]; then
    awk '
      /^MemTotal:/ {total = $2}
      /^MemAvailable:/ {available = $2}
      END {if (total > 0) printf "%d", 100 * (total - available) / total}
    ' /proc/meminfo
  fi
}

# List only Chrome commands with one of the known throwaway profile names.
profiles() {
  # We need the complete command line to recover the exact temporary profile.
  # shellcheck disable=SC2009
  ps -Ao command= 2>/dev/null \
    | grep -E -- '--user-data-dir=[^[:space:]]*/(lighthouse|chrome-launcher)\.|--user-data-dir=[^[:space:]]*/agent-browser-chrome-' \
    | grep -E "$CHROME_RE" \
    | grep -Ev "$NEVER_KILL_RE" \
    | sed -n 's/.*--user-data-dir=\([^ ]*\).*/\1/p' \
    | sort -u
}

profile_kind() {
  case "$1" in
    */lighthouse.*|*/chrome-launcher.*) echo launcher ;;
    */agent-browser-chrome-*) echo agent-browser ;;
    *) return 1 ;;
  esac
}

# Match the complete --user-data-dir value, then verify each PID still runs
# Chrome. This prevents prefix matches and excludes shells, Node, and agents.
profile_pids() {
  target="$1"
  ps -Ao pid=,command= 2>/dev/null |
    awk -v target="--user-data-dir=$target" '
      index($0, target) {
        tail = substr($0, index($0, target) + length(target))
        if (tail == "" || tail ~ /^[[:space:]]/) print $1
      }
    ' |
    while read -r pid; do
      cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
      printf '%s' "$cmd" | grep -Eq "$CHROME_RE" || continue
      printf '%s' "$cmd" | grep -Eq "$NEVER_KILL_RE" && continue
      echo "$pid"
    done
}

profile_main() {
  dir="$1"
  for pid in $(profile_pids "$dir"); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in *--type=*) continue ;; esac
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$ppid" ] && [ -n "$etime" ] || continue
    echo "$pid $ppid $etime"
    return 0
  done
  return 1
}

daemon_link_alive() {
  command -v lsof >/dev/null 2>&1 || return 0
  [ -n "$(lsof -a -p "$1" -iTCP -sTCP:ESTABLISHED -nP 2>/dev/null | tail -n +2)" ]
}

# Return a reason only for old launcher processes with a dead parent, or an
# old agent-browser profile whose daemon died or lost its DevTools connection.
orphan_reason() {
  dir="$1"
  kind="$(profile_kind "$dir")" || return 1
  info="$(profile_main "$dir" || true)"
  [ -n "$info" ] || return 1
  read -r pid ppid etime <<EOF
$info
EOF
  [ "$(etime_to_sec "$etime")" -ge "$MIN_AGE_SEC" ] || return 1
  if [ "$ppid" = "1" ]; then
    echo "orphaned $kind Chrome (parent exited)"
    return 0
  fi
  [ "$kind" = "agent-browser" ] || return 1
  parent="$(ps -o command= -p "$ppid" 2>/dev/null || true)"
  printf '%s' "$parent" | grep -Eq "$DAEMON_RE" || return 1
  printf '%s' "$parent" | grep -Eq "$CHROME_RE|$NEVER_KILL_RE" && return 1
  daemon_link_alive "$ppid" && return 1
  echo "orphaned agent-browser Chrome (daemon has no DevTools connection)"
}

profile_stats() {
  dir="$1"
  max_cpu=0
  renderer_pid=""
  rss_kb=0
  for pid in $(profile_pids "$dir"); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
    case "$rss" in ''|*[!0-9]*) rss=0 ;; esac
    rss_kb=$((rss_kb + rss))
    case "$cmd" in
      *--type=renderer*)
        cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')"
        case "$cpu" in ''|*[!0-9.]* ) cpu=0 ;; esac
        if awk -v value="$cpu" -v current="$max_cpu" 'BEGIN {exit !(value > current)}'; then
          max_cpu="$cpu"
          renderer_pid="$pid"
        fi
        ;;
    esac
  done
  echo "$max_cpu $renderer_pid $((rss_kb / 1024))"
}

reap_profile() {
  dir="$1"
  reason="$2"
  pids="$(profile_pids "$dir" || true)"
  [ -n "$pids" ] || return 0
  log "$reason: profile=$dir"
  # shellcheck disable=SC2086
  ps -o pid,ppid,etime,%cpu,rss,comm -p $pids 2>/dev/null || true
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: no processes signaled"
    return 0
  fi
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  sleep 2
  stragglers="$(profile_pids "$dir" || true)"
  if [ -n "$stragglers" ]; then
    log "sending SIGKILL to Chrome stragglers for $dir"
    # shellcheck disable=SC2086
    kill -KILL $stragglers 2>/dev/null || true
  fi
}

reap_orphans() {
  handled=0
  for dir in $(profiles); do
    reason="$(orphan_reason "$dir" || true)"
    if [ -n "$reason" ]; then
      reap_profile "$dir" "$reason"
      handled=$((handled + 1))
    fi
  done
  [ "$handled" -gt 0 ] || log "orphan scan: no abandoned headless Chrome profiles found"
}

reap_pressure() {
  ram_used="$(ram_used_percent || true)"
  ram_trigger=0
  if [ -n "$ram_used" ] && awk -v value="$ram_used" -v limit="$RAM_LIMIT" 'BEGIN {exit !(value >= limit)}'; then
    ram_trigger=1
  fi

  handled=0
  for dir in $(profiles); do
    [ "$(profile_kind "$dir")" = "agent-browser" ] || continue
    info="$(profile_main "$dir" || true)"
    [ -n "$info" ] || continue
    read -r _main_pid daemon_pid etime <<EOF
$info
EOF
    parent="$(ps -o command= -p "$daemon_pid" 2>/dev/null || true)"
    printf '%s' "$parent" | grep -Eq "$DAEMON_RE" || continue
    printf '%s' "$parent" | grep -Eq "$CHROME_RE|$NEVER_KILL_RE" && continue
    [ "$(etime_to_sec "$etime")" -ge "$MIN_AGE_SEC" ] || continue

    read -r cpu renderer_pid rss_mb <<EOF
$(profile_stats "$dir")
EOF
    cpu_trigger=0
    if [ -n "$renderer_pid" ] && awk -v value="$cpu" -v limit="$CPU_LIMIT" 'BEGIN {exit !(value >= limit)}'; then
      cpu_trigger=1
    fi
    ram_profile_trigger=0
    if [ "$ram_trigger" -eq 1 ] && [ "$rss_mb" -ge "$PROFILE_RSS_LIMIT_MB" ]; then
      ram_profile_trigger=1
    fi
    [ "$cpu_trigger" -eq 1 ] || [ "$ram_profile_trigger" -eq 1 ] || continue

    reason=""
    [ "$cpu_trigger" -eq 1 ] && reason="runaway renderer $renderer_pid at ${cpu}% CPU (limit ${CPU_LIMIT}%)"
    if [ "$ram_profile_trigger" -eq 1 ]; then
      [ -n "$reason" ] && reason="$reason; "
      reason="${reason}system RAM used ${ram_used}% (limit ${RAM_LIMIT}%), profile RSS ${rss_mb} MiB (limit ${PROFILE_RSS_LIMIT_MB} MiB)"
    fi
    reap_profile "$dir" "$reason"
    handled=$((handled + 1))
  done
  if [ "$handled" -eq 0 ]; then
    if [ -n "$ram_used" ]; then
      log "pressure scan: no agent-browser profile crossed thresholds (RAM used ${ram_used}%)"
    else
      log "pressure scan: no agent-browser profile crossed CPU threshold; RAM data unavailable"
    fi
  fi
}

reap_orphans
reap_pressure
