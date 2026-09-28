#!/usr/bin/env bash
# Keep temporary, headless agent-browser sessions within a small machine budget.
# One ps snapshot makes this safe to run before the slower checks every minute.
set -euo pipefail

MAX_RSS_MB="${CHROME_REAP_TOTAL_RSS_MB:-12288}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

profiles="$(mktemp "${TMPDIR:-/tmp}/browser-budget.XXXXXX")"
trap 'rm -f "$profiles"' EXIT

ps -axww -o pid=,ppid=,etime=,rss=,command= | awk -v home="$HOME" '
  function age(v, a,n,d) {
    d=0
    if (index(v,"-")) { d=substr(v,1,index(v,"-")-1); v=substr(v,index(v,"-")+1) }
    n=split(v,a,":")
    if (n==3) return d*86400+a[1]*3600+a[2]*60+a[3]
    if (n==2) return d*86400+a[1]*60+a[2]
    return 0
  }
  {
    pid=$1; parent[pid]=$2; elapsed=age($3); kb=$4; rss_pid[pid]=kb
    cmd=$0; for (i=1;i<=4;i++) sub(/^[[:space:]]*[^[:space:]]+/,"",cmd)
    sub(/^[[:space:]]+/,"",cmd)
    command[pid]=cmd
    if (index(cmd,home "/.agent-browser/browsers/")!=1) next
    if (match(cmd,/--user-data-dir=[^[:space:]]*\/agent-browser-chrome-[0-9a-f-]+/)==0) next
    profile=substr(cmd,RSTART,RLENGTH); sub(/^--user-data-dir=/,"",profile)
    rss[profile]+=kb
    if (cmd ~ /\/Google Chrome for Testing\.app\/Contents\/MacOS\/Google Chrome for Testing/ &&
        cmd ~ /--headless/ && cmd !~ /--type=/) {
      root[profile]=pid; started[profile]=elapsed
    }
  }
  END {
    for (profile in root) {
      p=root[profile]; daemon=parent[p]
      if (command[daemon] !~ /\/agent-browser-darwin-arm64$/) daemon=0
      printf "%d|%d|%d|%d|%s\n",started[profile],int((rss[profile]+rss_pid[daemon])/1024),p,daemon,profile
    }
  }
' | sort -t '|' -k1,1nr > "$profiles"

count="$(wc -l < "$profiles" | tr -d ' ')"
total="$(awk -F '|' '{s+=$2} END {print s+0}' "$profiles")"
log "test browsers: $count sessions, ${total}MiB RSS (limit ${MAX_RSS_MB}MiB)"
stopped=()

while IFS='|' read -r _age rss root daemon profile; do
  [ "$total" -gt "$MAX_RSS_MB" ] || break
  current="$(ps -p "$root" -o command= 2>/dev/null || true)"
  [[ "$current" == *"--user-data-dir=$profile"* && "$current" == *--headless* ]] || continue
  if [ "$DRY_RUN" -eq 1 ]; then
    log "WOULD REAP browser $root (${rss}MiB) $profile"
  else
    if [ "$daemon" -gt 1 ]; then
      daemon_cmd="$(ps -p "$daemon" -o command= 2>/dev/null || true)"
      case "$daemon_cmd" in */agent-browser-darwin-arm64) kill -TERM "$daemon" 2>/dev/null || true ;; esac
    fi
    kill -TERM "$root" 2>/dev/null || true
    log "REAPED browser $root (${rss}MiB) $profile"
    stopped+=("$root|$profile")
  fi
  total=$((total-rss))
done < "$profiles"

if [ "${#stopped[@]}" -gt 0 ]; then
  sleep 1
  for entry in "${stopped[@]}"; do
    root="${entry%%|*}"
    profile="${entry#*|}"
    current="$(ps -p "$root" -o command= 2>/dev/null || true)"
    [[ "$current" == *"--user-data-dir=$profile"* && "$current" == *--headless* ]] || continue
    kill -KILL "$root" 2>/dev/null || true
    log "forced browser $root"
  done
fi
