#!/usr/bin/env bash
# Limit detached Next dev servers left behind when their launchers exit.
set -euo pipefail

MAX_SERVERS="${NEXT_REAP_MAX_ORPHANS:-3}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

servers="$(mktemp "${TMPDIR:-/tmp}/next-orphans.XXXXXX")"
trap 'rm -f "$servers"' EXIT

ps -axww -o pid=,ppid=,etime=,command= | awk '
  function age(v,a,n,d) {
    d=0
    if (index(v,"-")) { d=substr(v,1,index(v,"-")-1); v=substr(v,index(v,"-")+1) }
    n=split(v,a,":")
    if (n==3) return d*86400+a[1]*3600+a[2]*60+a[3]
    if (n==2) return d*86400+a[1]*60+a[2]
    return 0
  }
  $2==1 {
    cmd=$0; for (i=1;i<=3;i++) sub(/^[[:space:]]*[^[:space:]]+/,"",cmd)
    sub(/^[[:space:]]+/,"",cmd)
    if (cmd ~ /^next-server \(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$/)
      print age($3),$1
  }
' | sort -k1,1nr > "$servers"

count="$(wc -l < "$servers" | tr -d ' ')"
log "orphan Next servers: $count (limit $MAX_SERVERS)"
stopped=()

while read -r _age pid; do
  [ "$count" -gt "$MAX_SERVERS" ] || break
  current="$(ps -p "$pid" -o ppid=,command= 2>/dev/null || true)"
  [[ "$current" =~ ^[[:space:]]*1[[:space:]]+next-server[[:space:]]+\(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$ ]] || continue
  if [ "$DRY_RUN" -eq 1 ]; then
    log "WOULD REAP orphan Next $pid"
  else
    kill -TERM "$pid" 2>/dev/null || true
    log "REAPED orphan Next $pid"
    stopped+=("$pid")
  fi
  count=$((count-1))
done < "$servers"

if [ "${#stopped[@]}" -gt 0 ]; then
  sleep 1
  for pid in "${stopped[@]}"; do
    current="$(ps -p "$pid" -o ppid=,command= 2>/dev/null || true)"
    [[ "$current" =~ ^[[:space:]]*1[[:space:]]+next-server[[:space:]]+\(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$ ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
    log "forced orphan Next $pid"
  done
fi
