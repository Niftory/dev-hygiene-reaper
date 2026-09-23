#!/usr/bin/env bash
#
# reap-idle-lsp.sh — close idle or runaway TypeScript language servers.
#
# Coding agents start a TypeScript language server per session. Each tsserver
# keeps its whole project graph resident, often 1-4 GiB, and it stays after
# the session goes quiet. A new request restarts it, so an idle one is safe
# to close. This reaper closes an LSP tree when:
#
#   idle      it is at least LSP_REAP_MIN_MB and has been idle for
#             LSP_REAP_IDLE_SEC;
#   pressure  swap use is at least LSP_REAP_PRESSURE_SWAP_MB and it has been
#             idle for LSP_REAP_PRESSURE_IDLE_SEC (largest first, one per run);
#   runaway   it is at least LSP_REAP_RUNAWAY_MB and older than
#             LSP_REAP_RUNAWAY_AGE_SEC, busy or not. This also covers a
#             standalone tsgo type check that has grown without bound.
#
# Editors (VS Code, Cursor, Zed, ...) disable a language server after repeated
# crashes, so trees owned by an editor are skipped unless
# LSP_REAP_EDITORS=1. Idle tracking and footprint accounting match
# reap-stale-dev-servers.sh; see lib/proc.sh.
#
# Usage:
#   reap-idle-lsp.sh [--dry-run] [--bootstrap-idle]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/proc.sh
. "$SCRIPT_DIR/lib/proc.sh"

MIN_MB="${LSP_REAP_MIN_MB:-768}"
IDLE_SEC="${LSP_REAP_IDLE_SEC:-1800}"
PRESSURE_SWAP_MB="${LSP_REAP_PRESSURE_SWAP_MB:-12288}"
PRESSURE_IDLE_SEC="${LSP_REAP_PRESSURE_IDLE_SEC:-600}"
RUNAWAY_MB="${LSP_REAP_RUNAWAY_MB:-6144}"
RUNAWAY_AGE_SEC="${LSP_REAP_RUNAWAY_AGE_SEC:-900}"
REAP_EDITORS="${LSP_REAP_EDITORS:-0}"
STATE_DIR="${DEV_HYGIENE_STATE_DIR:-$HOME/.dev-hygiene}"
STATE_FILE="$STATE_DIR/lsp-reaper-state"

LSP_RE='typescript-language-server|/typescript/lib/tsserver\.js|/tsgo( |$)|/native-preview[^ ]*/tsgo|vtsls'
EDITOR_RE='Code Helper|Visual Studio Code|Cursor|Windsurf|/Zed|/zed|nvim|/vim( |$)|emacs|JetBrains|WebStorm'

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --bootstrap-idle) export BOOTSTRAP_IDLE=1 ;;
  esac
done

mkdir -p "$STATE_DIR"
SNAP="$(mktemp -d "${TMPDIR:-/tmp}/lsp-reap.XXXXXX")"
trap 'rm -rf "$SNAP"' EXIT
# Take the clock first: ps reports ages relative to its own start.
now="$(date +%s)"
proc_snapshot "$SNAP"
swap_mb="$(swap_used_mb)"; swap_mb="${swap_mb:-0}"

# Root: the topmost LSP process in each chain. Its parent is the owner, used
# only to recognise editors.
/usr/bin/awk -v lsp="$LSP_RE" '
  {
    pid = $1; ppid[pid] = $2; c = $0
    for (i = 1; i <= 4; i++) sub(/^[^ ]+ /, "", c)
    cmd[pid] = c; order[++n] = pid
  }
  END {
    for (i = 1; i <= n; i++) {
      p = order[i]; if (cmd[p] !~ lsp) continue
      r = p
      while ((ppid[r] in cmd) && cmd[ppid[r]] ~ lsp) r = ppid[r]
      if (!(r in seen)) { seen[r] = 1; print r }
    }
  }' "$SNAP/ps" > "$SNAP/roots"

: > "$SNAP/state"
: > "$SNAP/reap"
: > "$SNAP/candidates"
tree_table "$SNAP" < "$SNAP/roots" | with_idle "$STATE_FILE" "$SNAP/state" "$now" > "$SNAP/table"

kept=0
while IFS="$US" read -r since root age _cpu mb count _dir owner cmd; do
  [ -n "$root" ] || continue
  idle=$(( now - since ))

  owner_kind="agent"
  [[ "$owner" =~ $EDITOR_RE ]] && owner_kind="editor"
  label="$cmd"; [[ "$cmd" =~ $LSP_RE ]] && label="${BASH_REMATCH[0]}"
  desc="root $root [${count} procs, ${mb}MiB, age $((age / 60))m, idle $((idle / 60))m, $owner_kind] $label <- ${owner:0:80}"

  if [ "$owner_kind" = editor ] && [ "$REAP_EDITORS" != 1 ]; then
    [ "$DRY_RUN" -eq 1 ] && log "keep (editor-owned) $desc"
    kept=$((kept + 1)); continue
  fi

  reason=""
  if [ "$mb" -ge "$RUNAWAY_MB" ] && [ "$age" -ge "$RUNAWAY_AGE_SEC" ]; then
    reason="runaway (${mb}MiB >= ${RUNAWAY_MB}MiB)"
  elif [ "$mb" -ge "$MIN_MB" ] && [ "$idle" -ge "$IDLE_SEC" ]; then
    reason="idle"
  fi

  if [ -n "$reason" ]; then
    echo "$root|$reason|$desc" >> "$SNAP/reap"
  else
    [ "$DRY_RUN" -eq 1 ] && log "keep $desc"
    kept=$((kept + 1))
    if [ "$mb" -ge "$MIN_MB" ] && [ "$idle" -ge "$PRESSURE_IDLE_SEC" ]; then
      echo "$mb $root|pressure (swap ${swap_mb}MiB >= ${PRESSURE_SWAP_MB}MiB)|$desc" >> "$SNAP/candidates"
    fi
  fi
done < "$SNAP/table"

if [ "$swap_mb" -ge "$PRESSURE_SWAP_MB" ] && [ ! -s "$SNAP/reap" ]; then
  sort -k1,1nr "$SNAP/candidates" | head -1 | cut -d' ' -f2- >> "$SNAP/reap"
  [ -s "$SNAP/reap" ] && kept=$((kept - 1))
fi

reaped=0
while IFS='|' read -r root reason desc; do
  [ -n "$root" ] || continue
  if [ "$DRY_RUN" -eq 1 ]; then
    log "WOULD REAP ($reason) $desc"
  else
    # shellcheck disable=SC2046
    forced="$(kill_tree $(tree_pids "$SNAP" "$root"))"
    log "REAPED ($reason) $desc${forced:+ — $forced needed KILL}"
  fi
  reaped=$((reaped + 1))
done < "$SNAP/reap"

[ "$DRY_RUN" -eq 1 ] || mv -f "$SNAP/state" "$STATE_FILE"
suffix=""; [ "$DRY_RUN" -eq 1 ] && suffix=" (dry-run)"
log "done: $reaped reaped, $kept kept, swap ${swap_mb}MiB$suffix"
