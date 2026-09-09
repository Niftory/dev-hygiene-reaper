#!/usr/bin/env bash
# Reap stale local development-service processes.
#
# This script is deliberately narrow. It recognizes only the local dev
# commands listed in service_kind(), requires an old process and two idle
# observations, and kills only that process and its children. It never walks
# upward to a shell, terminal, agent, or launchd.
#
# Run this from reaper.sh once per hour. The default two idle observations then
# represent about two hours. Use --dry-run before enabling a new service.
set -uo pipefail

AGE_MIN_SEC="${DEV_SERVICE_REAP_AGE_MIN_SEC:-7200}"
IDLE_CPU_SEC="${DEV_SERVICE_REAP_IDLE_CPU_SEC:-15}"
IDLE_RUNS_TO_REAP="${DEV_SERVICE_REAP_IDLE_RUNS:-2}"
STATE_DIR="${DEV_HYGIENE_STATE_DIR:-$HOME/.dev-hygiene}"
STATE_FILE="$STATE_DIR/dev-service-reaper-state"
NEW_STATE="$STATE_FILE.new"
SERVICES="${DEV_SERVICE_REAP_SERVICES:-inngest hatchet sst vite turbo}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

etime_to_sec() {
  local value="$1" days=0 rest hh=0 mm ss
  case "$value" in *-*) days="${value%%-*}"; rest="${value#*-}";; *) rest="$value";; esac
  local IFS=:
  set -- $rest
  case $# in
    3) hh="$1"; mm="$2"; ss="$3";;
    2) mm="$1"; ss="$2";;
    *) echo 0; return;;
  esac
  echo $(( 10#$days*86400 + 10#$hh*3600 + 10#$mm*60 + 10#$ss ))
}

cputime_to_sec() {
  awk -v value="$1" 'BEGIN {
    count = split(value, parts, ":")
    if (count == 2) printf "%d", parts[1] * 60 + parts[2]
    else if (count == 3) printf "%d", parts[1] * 3600 + parts[2] * 60 + parts[3]
    else print 0
  }'
}

prev_for() { awk -v process="$1" '$1 == process { print $2, $3 }' "$STATE_FILE" 2>/dev/null; }

# Return a stable service kind only for an explicit local development command.
# Do not broaden these patterns to a bare service name: application code often
# includes the same name and must never become a kill candidate.
service_kind() {
  local service="$1" command="$2"
  case "$service" in
    inngest)
      case "$command" in
        *inngest-cli*' dev '*|*'inngest dev '*|*'inngest-cli dev') echo inngest;;
      esac
      ;;
    hatchet)
      case "$command" in
        *'hatchet dev '*|*'hatchet dev'|*hatchet-local*' server'*) echo hatchet;;
      esac
      ;;
    sst)
      case "$command" in
        *'node_modules/.bin/sst dev '*|*'node_modules/.bin/sst dev'|*' sst dev '*|*' sst dev') echo sst;;
      esac
      ;;
    vite)
      case "$command" in
        *'/node_modules/vite/bin/vite.js '*|*'/node_modules/vite/bin/vite.js'|*'node_modules/.bin/vite '*|*'node_modules/.bin/vite') echo vite;;
      esac
      ;;
    turbo)
      case "$command" in
        *'/node_modules/turbo/bin/turbo '*|*'/node_modules/turbo/bin/turbo'|*'node_modules/.bin/turbo '*)
          case "$command" in
            *' turbo dev '*|*'/turbo dev '*|*' turbo dev'|*'/turbo dev'|\
            *' turbo daemon '*|*'/turbo daemon '*|*' turbo daemon'|*'/turbo daemon') echo turbo;;
          esac
          ;;
      esac
      ;;
  esac
}

tree_pids() {
  local pid="$1" child
  echo "$pid"
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do tree_pids "$child"; done
}

add_tree_once() {
  local pid="$1" child
  case " $REAP_PIDS " in *" $pid "*) return;; esac
  REAP_PIDS="$REAP_PIDS $pid"
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do add_tree_once "$child"; done
}

mkdir -p "$STATE_DIR"
: > "$NEW_STATE"
reaped=0
kept=0
REAP_PIDS=""

for service in $SERVICES; do
  while read -r pid etime cputime command; do
    [ -n "${pid:-}" ] || continue
    kind="$(service_kind "$service" "$command")"
    [ -n "$kind" ] || continue

    age_sec="$(etime_to_sec "$etime")"
    cpu_sec="$(cputime_to_sec "$cputime")"
    read -r previous_cpu previous_idle <<EOF
$(prev_for "$pid")
EOF
    idle_runs=0
    if [ -n "${previous_cpu:-}" ]; then
      delta=$(( cpu_sec - previous_cpu ))
      [ "$delta" -lt 0 ] && delta=0
      [ "$delta" -lt "$IDLE_CPU_SEC" ] && idle_runs=$(( ${previous_idle:-0} + 1 ))
    fi

    if [ "$age_sec" -ge "$AGE_MIN_SEC" ] && [ "$idle_runs" -ge "$IDLE_RUNS_TO_REAP" ]; then
      action="REAPED"
      [ "$DRY_RUN" -eq 1 ] && action="WOULD REAP"
      log "$action $kind $pid (age ${age_sec}s, idle ${idle_runs} runs)"
      if [ "$DRY_RUN" -eq 0 ]; then add_tree_once "$pid"; fi
      reaped=$(( reaped + 1 ))
      [ "$DRY_RUN" -eq 1 ] && echo "$pid $cpu_sec ${previous_idle:-0}" >> "$NEW_STATE"
    else
      echo "$pid $cpu_sec $idle_runs" >> "$NEW_STATE"
      kept=$(( kept + 1 ))
    fi
  done < <(ps -axo pid=,etime=,cputime=,command=)
done

if [ "$DRY_RUN" -eq 1 ]; then
  rm -f "$NEW_STATE"
elif [ -n "$REAP_PIDS" ]; then
  for pid in $REAP_PIDS; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  forced=0
  for pid in $REAP_PIDS; do
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; forced=$(( forced + 1 )); fi
  done
  mv -f "$NEW_STATE" "$STATE_FILE"
  log "terminated ${reaped} service candidates (${forced} required KILL)"
else
  mv -f "$NEW_STATE" "$STATE_FILE"
fi

suffix=""; [ "$DRY_RUN" -eq 1 ] && suffix=" (dry-run)"
log "done: ${reaped} candidates, ${kept} kept${suffix}"
