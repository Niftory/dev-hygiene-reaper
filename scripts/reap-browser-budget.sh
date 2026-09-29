#!/usr/bin/env bash
# Keep temporary browsers and Next dev servers within one machine budget.
# One ps snapshot makes this safe to run every 10 seconds.
set -euo pipefail

MAX_RSS_MB="${TEST_REAP_TOTAL_RSS_MB:-${CHROME_REAP_TOTAL_RSS_MB:-8192}}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

workloads="$(mktemp "${TMPDIR:-/tmp}/test-budget.XXXXXX")"
trap 'rm -f "$workloads"' EXIT

ps -axww -o pid=,ppid=,etime=,rss=,command= | awk -v home="$HOME" '
  function age(v, a,n,d) {
    d=0
    if (index(v,"-")) { d=substr(v,1,index(v,"-")-1); v=substr(v,index(v,"-")+1) }
    n=split(v,a,":")
    if (n==3) return d*86400+a[1]*3600+a[2]*60+a[3]
    if (n==2) return d*86400+a[1]*60+a[2]
    return 0
  }
  function in_tree(pid, root, n) {
    for (n=0; pid>1 && n<100; n++) {
      if (pid==root) return 1
      pid=parent[pid]
    }
    return 0
  }
  {
    pid=$1; parent[pid]=$2; elapsed=age($3); kb=$4; rss_pid[pid]=kb
    cmd=$0; for (i=1;i<=4;i++) sub(/^[[:space:]]*[^[:space:]]+/,"",cmd)
    sub(/^[[:space:]]+/,"",cmd)
    command[pid]=cmd
    if (cmd ~ /^next-server \(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$/)
      next_root[pid]=elapsed
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
      printf "B|%d|%d|%d|%d|%s\n",started[profile],int((rss[profile]+rss_pid[daemon])/1024),p,daemon,profile
    }
    for (root_pid in next_root) {
      kb=0
      for (pid in rss_pid) if (in_tree(pid,root_pid)) kb+=rss_pid[pid]
      printf "N|%d|%d|%d|0|next-server\n",next_root[root_pid],int(kb/1024),root_pid
    }
  }
' | sort -t '|' -k3,3nr -k2,2nr > "$workloads"

browser_count="$(awk -F '|' '$1=="B" {n++} END {print n+0}' "$workloads")"
next_count="$(awk -F '|' '$1=="N" {n++} END {print n+0}' "$workloads")"
total="$(awk -F '|' '{s+=$3} END {print s+0}' "$workloads")"
log "test workloads: $browser_count browsers, $next_count Next servers, ${total}MiB RSS (limit ${MAX_RSS_MB}MiB)"
stopped=()

while IFS='|' read -r kind _age rss root daemon profile; do
  [ "$total" -gt "$MAX_RSS_MB" ] || break
  current="$(ps -p "$root" -o command= 2>/dev/null || true)"
  if [ "$kind" = B ]; then
    [[ "$current" == *"--user-data-dir=$profile"* && "$current" == *--headless* ]] || continue
  else
    [[ "$current" =~ ^next-server[[:space:]]+\(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$ ]] || continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "WOULD REAP $kind $root (${rss}MiB) $profile"
  else
    if [ "$kind" = B ] && [ "$daemon" -gt 1 ]; then
      daemon_cmd="$(ps -p "$daemon" -o command= 2>/dev/null || true)"
      case "$daemon_cmd" in */agent-browser-darwin-arm64) kill -TERM "$daemon" 2>/dev/null || true ;; esac
    fi
    kill -TERM "$root" 2>/dev/null || true
    log "REAPED $kind $root (${rss}MiB) $profile"
    stopped+=("$kind|$root|$profile")
  fi
  total=$((total-rss))
done < "$workloads"

if [ "${#stopped[@]}" -gt 0 ]; then
  sleep 1
  for entry in "${stopped[@]}"; do
    kind="${entry%%|*}"
    entry="${entry#*|}"
    root="${entry%%|*}"
    profile="${entry#*|}"
    current="$(ps -p "$root" -o command= 2>/dev/null || true)"
    if [ "$kind" = B ]; then
      [[ "$current" == *"--user-data-dir=$profile"* && "$current" == *--headless* ]] || continue
    else
      [[ "$current" =~ ^next-server[[:space:]]+\(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$ ]] || continue
    fi
    kill -KILL "$root" 2>/dev/null || true
    log "forced $kind $root"
  done
fi
