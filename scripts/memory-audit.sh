#!/usr/bin/env bash
#
# memory-audit.sh — read-only report of where memory is going and what the
# memory-lane reapers would do about it. It signals nothing.
#
# Usage:
#   memory-audit.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/proc.sh
. "$SCRIPT_DIR/lib/proc.sh"

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/mem-audit.XXXXXX")"
trap 'rm -rf "$SNAP"' EXIT
proc_snapshot "$SNAP"

echo "== system"
echo "RAM $(( $(sysctl -n hw.memsize) / 1073741824 )) GiB, swap used $(swap_used_mb) MiB"
/usr/bin/memory_pressure 2>/dev/null | grep -E "free percentage" | sed 's/^/  /'

echo
echo "== footprint by app (MiB, >= 500)"
# Group each process by its .app bundle, or by executable name otherwise.
/usr/bin/awk '
  FILENAME == ARGV[1] { mem[$1] = $2; next }
  {
    c = $0; for (i = 1; i <= 4; i++) sub(/^[^ ]+ /, "", c)
    if (match(c, /\/[^\/]+\.app\//)) g = substr(c, RSTART + 1, RLENGTH - 2)
    else { split(c, t, " "); g = t[1]; sub(/.*\//, "", g) }
    sum[g] += mem[$1]; cnt[g]++
  }
  END { for (g in sum) if (sum[g] >= 500) printf "%8d  %4d procs  %s\n", sum[g], cnt[g], g }
' "$SNAP/mem" "$SNAP/ps" | sort -nr

echo
echo "== dev-server trees (dry run)"
bash "$SCRIPT_DIR/reap-stale-dev-servers.sh" --dry-run | sed 's/^\[[^]]*\] /  /'
echo
echo "== language servers (dry run)"
bash "$SCRIPT_DIR/reap-idle-lsp.sh" --dry-run | sed 's/^\[[^]]*\] /  /'
echo
echo "== personal Chrome"
bash "$SCRIPT_DIR/reap-chrome-tab-cap.sh" --dry-run | sed 's/^\[[^]]*\] /  /'
