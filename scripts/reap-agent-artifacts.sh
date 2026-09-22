#!/usr/bin/env bash
# Remove stale temporary directories created by local coding agents.
set -uo pipefail

TMP_ROOT="${AGENT_ARTIFACT_TMP_ROOT:-/private/tmp}"
MAX_AGE_DAYS="${AGENT_ARTIFACT_MAX_AGE_DAYS:-1}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

case "$MAX_AGE_DAYS" in
  ''|*[!0-9]*|0) log "AGENT_ARTIFACT_MAX_AGE_DAYS must be a positive integer — skip"; exit 0 ;;
esac
[ -d "$TMP_ROOT" ] || { log "temporary root is missing — skip: $TMP_ROOT"; exit 0; }

process_snapshot="$(ps -ww -axo command= 2>/dev/null || true)"
if [ -z "$process_snapshot" ]; then
  log "process snapshot unavailable — skip cleanup"
  exit 0
fi

is_active() {
  case "$process_snapshot" in
    *"$1"/*|*"$1 "*|*"$1") return 0 ;;
  esac
  return 1
}

removed=0
kept=0
while IFS= read -r candidate; do
  [ -d "$candidate" ] || continue
  if is_active "$candidate"; then
    log "active — keep: $candidate"
    kept=$((kept + 1))
    continue
  fi
  log "remove stale agent artifact $(human "$candidate"): $candidate"
  find "$candidate" -depth -delete 2>/dev/null || log "could not fully remove: $candidate"
  removed=$((removed + 1))
done < <(
  find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+$((MAX_AGE_DAYS - 1))" \
    \( -name 'sift-*' -o -name 'codex-*' -o -name 'claude-*' \
       -o -name 'agent-*' -o -name 'luna-*' -o -name 'worktable-*' \
       -o -name 'pr[0-9]*' \) -print 2>/dev/null
)

# These directories contain disposable scratch data. Keep recent items to
# protect active and resumable tasks. Do not touch task history or profiles.
for cache_root in "$HOME/.codex/.tmp" "$HOME/.agent-browser/tmp"; do
  [ -d "$cache_root" ] || continue
  find "$cache_root" -mindepth 1 -mtime +6 -depth -delete 2>/dev/null || true
done

log "done: removed $removed, active kept $kept"
