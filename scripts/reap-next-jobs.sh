#!/usr/bin/env bash
#
# reap-next-jobs.sh — close a runaway local Next.js process tree.
#
# This is an emergency brake for a leaking Next server, not a swap-pressure
# reaper. Earlier versions also closed Next trees whenever swap was high. That
# went wrong twice. macOS swap stays allocated long after the pressure that
# caused it, and RSS undercounts a server that sits in swap. The rule then
# closed the active, recently started servers every few minutes, while the
# stale ones that actually filled swap survived. reap-stale-dev-servers.sh now
# handles pressure by closing idle trees first.
#
# This script closes the single largest Next tree, by physical footprint,
# when it is at least NEXT_REAP_TREE_MAX_MB and older than
# NEXT_REAP_MIN_AGE_SEC. The ceiling is well above a normal dev server, so
# only a leak reaches it. The reaper targets only Next's known executable
# paths and process titles, includes their children, and never walks up to a
# shell, pnpm, or an agent.
#
# Usage:
#   reap-next-jobs.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/proc.sh
. "$SCRIPT_DIR/lib/proc.sh"

TREE_MAX_MB="${NEXT_REAP_TREE_MAX_MB:-6144}"
MIN_AGE_SEC="${NEXT_REAP_MIN_AGE_SEC:-600}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Process titles vary by Next and Node version. These patterns cover the
# executable path used by package managers and the next-server title Next sets
# for its actual server process. A plain `next` word is never enough to match.
NEXT_RE='/node_modules/next/|/node_modules/\.bin/next|/node_modules/\.bin/\.\./next/|^next-server |next-dev-server|next-start-server'

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/next-reap.XXXXXX")"
trap 'rm -rf "$SNAP"' EXIT
proc_snapshot "$SNAP"

# Keep only the highest Next process in each tree.
/usr/bin/awk -v re="$NEXT_RE" '
  {
    pid = $1; ppid[pid] = $2; c = $0
    for (i = 1; i <= 4; i++) sub(/^[^ ]+ /, "", c)
    if (c ~ re) next_pid[pid] = 1
  }
  END { for (p in next_pid) if (!(ppid[p] in next_pid)) print p }
' "$SNAP/ps" > "$SNAP/roots"

[ -s "$SNAP/roots" ] || { log "done: no local Next processes"; exit 0; }

best=""; best_mb=0; roots=0
while read -r root; do
  roots=$((roots + 1))
  age="$(field_of "$SNAP" "$root" 3)"
  read -r mb _cpu _count <<EOF
$(tree_stats "$SNAP" "$root")
EOF
  [ "${age:-0}" -ge "$MIN_AGE_SEC" ] || continue
  if [ "$mb" -ge "$TREE_MAX_MB" ] && [ "$mb" -gt "$best_mb" ]; then
    best="$root"; best_mb="$mb"
  fi
done < "$SNAP/roots"

if [ -z "$best" ]; then
  log "done: $roots Next roots below ${TREE_MAX_MB}MiB"
  exit 0
fi

cwd="$(cwd_of "$SNAP" "$best")"
if [ "$DRY_RUN" -eq 1 ]; then
  log "WOULD REAP Next root $best (footprint ${best_mb}MiB >= ${TREE_MAX_MB}MiB) ${cwd/#$HOME/~}"
  exit 0
fi
# shellcheck disable=SC2046
forced="$(kill_tree $(tree_pids "$SNAP" "$best"))"
log "REAPED Next root $best (footprint ${best_mb}MiB >= ${TREE_MAX_MB}MiB) ${cwd/#$HOME/~} — $forced needed KILL"
