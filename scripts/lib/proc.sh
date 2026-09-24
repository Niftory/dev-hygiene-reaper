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
# In a memory emergency, `top` itself can take a minute, so proc_snapshot
# --fast falls back to RSS from `ps`. RSS undercounts swapped memory, so the
# reapers then rank by age instead of size.
#
# Snapshot files (all under one directory):
#   ps   — pid ppid age_sec cpu_sec command...
#   mem  — pid footprint_mb
#   cwd  — pid<TAB>cwd

# shellcheck disable=SC2034  # used by the scripts that source this file
US=$'\037'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

swap_used_mb() {
  /usr/sbin/sysctl -n vm.swapusage 2>/dev/null | /usr/bin/awk '
    { for (i = 1; i <= NF; i++) if ($i == "used" && $(i + 1) == "=") {
        v = $(i + 2); u = substr(v, length(v), 1); gsub(/[A-Za-z]/, "", v)
        if (u == "G") print int(v * 1024); else print int(v); exit } }'
}

# memory_emergency — true when the kernel reports critical memory pressure,
# or swap use reaches EMERGENCY_SWAP_MB. Both checks are a single sysctl.
memory_emergency() {
  local level used
  level="$(/usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 1)"
  [ "${level:-1}" -ge 4 ] && return 0
  used="$(swap_used_mb)"
  [ "${used:-0}" -ge "${EMERGENCY_SWAP_MB:-24576}" ]
}

# proc_snapshot DIR [--fast] — write the ps, mem, and cwd snapshot files into
# DIR. --fast takes memory from ps RSS instead of top's footprint.
proc_snapshot() {
  local dir="$1" fast="${2:-}"
  /bin/ps -axww -o pid=,ppid=,etime=,time=,rss=,command= 2>/dev/null | /usr/bin/awk -v mem="$dir/mem" -v fast="$fast" '
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
      for (i = 1; i <= 5; i++) { sub(/^[ \t]*[^ \t]+/, "", cmd) }
      sub(/^[ \t]+/, "", cmd)
      print $1, $2, etime($3), cputime($4), cmd
      if (fast == "--fast") print $1, int($5 / 1024) > mem
    }' > "$dir/ps"

  [ "$fast" = "--fast" ] || /usr/bin/top -l 1 -n 5000 -stats pid,mem 2>/dev/null | /usr/bin/awk '
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

# tree_table DIR [MEMBERS_FILE] — read root pids on stdin and print one
# line per live root, all in a single pass. Fields are separated by the ASCII
# unit separator ($US), which, unlike a tab, `read` never collapses when a
# field is empty:
#   root age_sec cpu_sec footprint_mb procs cwd parent_command command
# Commands are cut to 200 characters. When MEMBERS_FILE is given, every pid
# inside the trees is written to it. Under heavy swap every process spawn is
# slow, so the reapers must not run a command per root.
tree_table() {
  /usr/bin/awk -v members="${2:-}" '
    FILENAME == ARGV[1] { mem[$1] = $2; next }
    FILENAME == ARGV[2] { split($0, f, "\t"); cwd[f[1]] = f[2]; next }
    FILENAME == ARGV[3] {
      parent[$1] = $2; age[$1] = $3; cpu[$1] = $4; pids[++n] = $1
      c = $0; for (i = 1; i <= 4; i++) sub(/^[^ ]+ /, "", c); cmd[$1] = substr(c, 1, 200)
      next
    }
    { roots[$1] = 1; order[++m] = $1 }
    END {
      for (i = 1; i <= n; i++) {
        p = pids[i]; q = p; hops = 0
        while (q != "" && q > 1 && hops++ < 64) {
          if (q in roots) {
            M[q] += mem[p]; C[q] += cpu[p]; N[q]++
            if (members != "") print p > members
            break
          }
          q = parent[q]
        }
      }
      for (j = 1; j <= m; j++) {
        r = order[j]; if (!(r in age)) continue
        printf "%s\037%d\037%d\037%d\037%d\037%s\037%s\037%s\n", r, age[r], C[r], M[r], N[r], cwd[r], cmd[parent[r]], cmd[r]
      }
    }' "$1/mem" "$1/cwd" "$1/ps" -
}

# worktree_of PATH — the nearest enclosing directory with a .git entry, or
# PATH itself. Uses only shell built-ins, so it costs no process spawn.
worktree_of() {
  local dir="$1"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ -e "$dir/.git" ] && { echo "$dir"; return; }
    dir="${dir%/*}"
  done
  echo "$1"
}

# Idle tracking. A tree is idle while its total CPU time grows by less than
# IDLE_CPU_PERCENT of wall time between runs. with_idle reads tree_table lines
# on stdin, prefixes each with its idle-since epoch, and writes the new state
# to NEW_STATE. State lines are:
#   pid start_epoch cpu_sec idle_since_epoch observed_epoch
# The start epoch guards against pid reuse. It may drift by up to 60s,
# because a slow snapshot skews it. BOOTSTRAP_IDLE=1 treats trees seen for
# the first time as idle since they started, for one-shot manual cleanups.
with_idle() {
  local state="$1" new_state="$2" now="$3"
  touch "$state"
  /usr/bin/awk -F '\037' -v now="$now" -v pct="${IDLE_CPU_PERCENT:-3}" \
    -v boot="${BOOTSTRAP_IDLE:-0}" -v out="$new_state" '
    FILENAME == ARGV[1] { split($0, s, " "); st[s[1]] = s[2]; last[s[1]] = s[3]; since[s[1]] = s[4]; stamp[s[1]] = s[5]; next }
    {
      pid = $1; start = now - $2; cpu = $3
      if ((pid in st) && (st[pid] - start) * (st[pid] - start) <= 3600) {
        elapsed = now - stamp[pid]; if (elapsed < 1) elapsed = 1
        idle = ((cpu - last[pid]) * 100 > pct * elapsed) ? now : since[pid]
      } else idle = (boot == 1 ? start : now)
      print pid, start, cpu, idle, now > out
      print idle "\037" $0
    }' "$state" -
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
