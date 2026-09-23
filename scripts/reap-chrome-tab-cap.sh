#!/usr/bin/env bash
#
# reap-chrome-tab-cap.sh — hold the personal Google Chrome under a memory cap.
#
# reap-runaway-chrome.sh handles automation profiles and never touches the
# personal browser. This script covers the personal browser. When the total
# physical footprint of every process in CHROME_TAB_CAP_APP exceeds
# CHROME_TAB_CAP_MB, it closes the largest renderer (tab) processes until the
# total is back under the cap. A closed tab shows "Aw, Snap!" and reloads on
# demand. The browser, GPU, network, and utility processes are never signalled.
#
# Usage:
#   reap-chrome-tab-cap.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/proc.sh
. "$SCRIPT_DIR/lib/proc.sh"

CAP_MB="${CHROME_TAB_CAP_MB:-24576}"
APP="${CHROME_TAB_CAP_APP:-/Applications/Google Chrome.app}"
NOTIFY="${CHROME_TAB_CAP_NOTIFY:-1}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

pids="$(pgrep -f "^$APP/" | tr '\n' ' ')"
[ -n "$pids" ] || { log "Chrome not running"; exit 0; }

# pid footprint_mb for every process of this Chrome install, largest first.
data="$(/usr/bin/top -l 1 -n 5000 -stats pid,mem 2>/dev/null | /usr/bin/awk -v p="$pids" '
  BEGIN { n = split(p, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
  want[$1] {
    m = $2; sub(/[+-]$/, "", m); v = m + 0
    if (m ~ /G$/) v *= 1024; else if (m ~ /K$/) v /= 1024
    else if (m ~ /B$/ || m ~ /^[0-9.]+$/) v /= 1048576
    printf "%d %d\n", $1, v
  }' | sort -k2,2nr)"
total="$(printf '%s\n' "$data" | /usr/bin/awk '{ s += $2 } END { print int(s) }')"

if [ "$total" -le "$CAP_MB" ]; then
  log "Chrome ${total}MiB / ${CAP_MB}MiB cap"
  exit 0
fi

log "Chrome ${total}MiB > ${CAP_MB}MiB cap — closing largest tabs"
closed=0
while read -r pid mb; do
  [ "$total" -le "$CAP_MB" ] && break
  [ -n "$pid" ] || continue
  cmd="$(ps -ww -o command= -p "$pid" 2>/dev/null)"
  case "$cmd" in *"Helper (Renderer)"*--type=renderer*) ;; *) continue ;; esac
  # Extension renderers back installed extensions, not tabs; leave them.
  case "$cmd" in *--extension-process*) continue ;; esac
  if [ "$DRY_RUN" -eq 1 ]; then
    log "  WOULD CLOSE renderer $pid (${mb}MiB)"
  else
    kill -KILL "$pid" 2>/dev/null && log "  closed renderer $pid (${mb}MiB)"
  fi
  total=$((total - mb)); closed=$((closed + 1))
done <<EOF
$data
EOF

if [ "$closed" -gt 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$NOTIFY" = 1 ]; then
  /usr/bin/osascript -e "display notification \"Closed $closed tab process(es) to stay under $((CAP_MB / 1024)) GB\" with title \"Chrome memory cap\"" >/dev/null 2>&1 || true
fi
log "done: $closed renderer(s) closed, Chrome now ~${total}MiB"
