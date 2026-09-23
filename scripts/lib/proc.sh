# shellcheck shell=bash
#
# lib/proc.sh — shared process-snapshot helpers for the memory-lane reapers.
#
# Why a snapshot: the memory-lane reapers reason about whole process trees
# (a pnpm wrapper, its Next server, and its workers). Asking `ps` once per
# process is slow and racy. Instead, each run takes one `ps`, one `top`, and
# one `lsof` snapshot. Awk then derives trees, owners, and totals from them.
#
# Why footprint and not RSS: macOS compresses and swaps idle memory. A
# day-old dev server that sits in swap has a tiny RSS but a large physical
# footprint. Ranking by RSS spares exactly the stale processes that fill swap
# and picks the active ones instead. `top`'s MEM column is the footprint that
# Activity Monitor and the Force Quit dialog show, so the reapers use it.
#
# Snapshot files (all under one directory):
#   ps   — pid ppid age_sec cpu_sec command...
#   mem  — pid footprint_mb
#   cwd  — pid<TAB>cwd

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

swap_used_mb() {
  /usr/sbin/sysctl -n vm.swapusage 2>/dev/null | /usr/bin/awk '
    { for (i = 1; i <= NF; i++) if ($i == "used" && $(i + 1) == "=") {
        v = $(i + 2); u = substr(v, length(v), 1); gsub(/[A-Za-z]/, "", v)
        if (u == "G") print int(v * 1024); else print int(v); exit } }'
}

# proc_snapshot DIR — write the ps, mem, and cwd snapshot files into DIR.
proc_snapshot() {
  local dir="$1"
  /bin/ps -axww -o pid=,ppid=,etime=,time=,command= 2>/dev/null | /usr/bin/awk '
    function etime(v,   d, n, p) {
      d = 0
      if (index(v, "-")) { d = substr(v, 1, index(v, "-") - 1); v = substr(v, index(v, "-") + 1) }
      n = split(v, p, ":")
      if (n == 3) return d * 86400 + p[1] * 3600 + p[2] * 60 + p[3]
      if (n == 2) return d * 86400 + p[1] * 60 + p[2]
      return 0
    }
    function cputime(v,   d, n, p) {
      d = 0
      if (index(v, "-")) { d = substr(v, 1, index(v, "-") - 1); v = substr(v, index(v, "-") + 1) }
      n = split(v, p, ":")
      if (n == 3) return int(d * 86400 + p[1] * 3600 + p[2] * 60 + p[3])
      if (n == 2) return int(d * 86400 + p[1] * 60 + p[2])
      return 0
    }
    {
      cmd = $0
      for (i = 1; i <= 4; i++) { sub(/^[ \t]*[^ \t]+/, "", cmd) }
      sub(/^[ \t]+/, "", cmd)
      print $1, $2, etime($3), cputime($4), cmd
    }' > "$dir/ps"

  /usr/bin/top -l 1 -n 5000 -stats pid,mem 2>/dev/null | /usr/bin/awk '
    $1 ~ /^[0-9]+$/ {
      m = $2; sub(/[+-]$/, "", m); v = m + 0
      if (m ~ /G$/) v *= 1024
      else if (m ~ /K$/) v /= 1024
      else if (m ~ /B$/ || m ~ /^[0-9.]+$/) v /= 1048576
      print $1, int(v)
    }' > "$dir/mem"

  /usr/sbin/lsof -nP -d cwd -Fpn 2>/dev/null | /usr/bin/awk '
    /^p/ { pid = substr($0, 2) }
    /^n/ { print pid "\t" substr($0, 2) }' > "$dir/cwd"
}

# tree_pids DIR ROOT — ROOT and every descendant, one pid per line.
tree_pids() {
  /usr/bin/awk -v root="$2" '
    { parent[$1] = $2; pids[++n] = $1 }
    END {
      for (i = 1; i <= n; i++) {
        p = pids[i]; q = p; hops = 0
        while (q != "" && q > 1 && hops++ < 64) {
          if (q == root) { print p; break }
          q = parent[q]
        }
      }
    }' "$1/ps"
}

# tree_stats DIR ROOT — "footprint_mb cpu_sec process_count" for ROOT's tree.
tree_stats() {
  local dir="$1" root="$2"
  tree_pids "$dir" "$root" | /usr/bin/awk '
    FILENAME == ARGV[1] { mem[$1] = $2; next }
    FILENAME == ARGV[2] { cpu[$1] = $4; next }
    { m += mem[$1]; c += cpu[$1]; n++ }
    END { printf "%d %d %d\n", m, c, n }' "$dir/mem" "$dir/ps" -
}

field_of() { /usr/bin/awk -v p="$2" -v f="$3" '$1 == p { print $f; exit }' "$1/ps"; }
command_of() {
  /usr/bin/awk -v p="$2" '$1 == p { $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print; exit }' "$1/ps"
}
cwd_of() { /usr/bin/awk -F '\t' -v p="$2" '$1 == p { print $2; exit }' "$1/cwd"; }

# worktree_of PATH — the enclosing Git top level, or PATH itself.
worktree_of() {
  local top
  top="$(/usr/bin/git -C "$1" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ] && { echo "$top"; return; }
  echo "$1"
}

# Idle tracking. A tree is idle while its total CPU time grows by less than
# IDLE_CPU_PERCENT of wall time between runs. State lines are:
#   pid start_epoch cpu_sec idle_since_epoch observed_epoch
# The start epoch guards against pid reuse. BOOTSTRAP_IDLE=1 treats trees seen
# for the first time as idle since they started, for one-shot manual cleanups.
idle_since() {
  local state="$1" pid="$2" start="$3" cpu="$4" now="$5" pct="${IDLE_CPU_PERCENT:-3}"
  /usr/bin/awk -v pid="$pid" -v start="$start" -v cpu="$cpu" -v now="$now" \
    -v pct="$pct" -v boot="${BOOTSTRAP_IDLE:-0}" '
    $1 == pid && ($2 - start) * ($2 - start) <= 100 { seen = 1; last = $3; since = $4; stamp = $5 }
    END {
      if (!seen) { print (boot == 1 ? start : now); exit }
      elapsed = now - stamp; if (elapsed < 1) elapsed = 1
      if ((cpu - last) * 100 > pct * elapsed) print now
      else print since
    }' "$state" 2>/dev/null || echo "$now"
}

# is_under PATH ROOT — true when PATH is ROOT or inside it.
is_under() { case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac; }

# kill_tree PIDS... — TERM, wait, then KILL the survivors. Returns KILL count.
kill_tree() {
  local pid forced=0
  for pid in "$@"; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep "${REAP_GRACE_SEC:-3}"
  for pid in "$@"; do
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; forced=$((forced + 1)); fi
  done
  echo "$forced"
}
