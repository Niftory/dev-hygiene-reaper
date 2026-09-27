#!/usr/bin/env bash
# Remove stale temporary directories created by local coding agents.
set -uo pipefail

TMP_ROOT="${AGENT_ARTIFACT_TMP_ROOT:-/private/tmp}"
SYSTEM_TMP_ROOT="${AGENT_ARTIFACT_SYSTEM_TMP_ROOT:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}"
MAX_AGE_DAYS="${AGENT_ARTIFACT_MAX_AGE_DAYS:-1}"
STATE_DIR="${DEV_HYGIENE_STATE_DIR:-$HOME/.dev-hygiene}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

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
system_removed=0
while IFS= read -r candidate; do
  [ -d "$candidate" ] || continue
  if is_active "$candidate"; then
    log "active — keep: $candidate"
    kept=$((kept + 1))
    continue
  fi
  log "remove stale agent artifact: $candidate"
  find "$candidate" -depth -delete 2>/dev/null || log "could not fully remove: $candidate"
  removed=$((removed + 1))
done < <(
  find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+$((MAX_AGE_DAYS - 1))" \
    \( -name 'sift-*' -o -name 'codex-*' -o -name 'claude-*' \
       -o -name 'agent-*' -o -name 'luna-*' -o -name 'worktable-*' \
       -o -name 'pr[0-9]*' \) -print 2>/dev/null
)

clean_system_temp() {
  local root="$1" active_file="$STATE_DIR/temp-active.$$" snapshot_file="$STATE_DIR/temp-processes.$$" recent_file="$STATE_DIR/temp-recent.$$" name path relative
  local -a exclude=()
  [ -d "$root" ] || return
  root="$(cd "$root" 2>/dev/null && pwd -P)" || return
  printf '%s\n' "$process_snapshot" > "$snapshot_file"
  : > "$active_file"

  if command -v lsof >/dev/null 2>&1; then
    if ! lsof -nP -Fpn 2>/dev/null | awk -v prefix="$root/" '
      /^n/ {
        path = substr($0, 2)
        if (index(path, prefix) == 1) {
          rest = substr(path, length(prefix) + 1)
          split(rest, parts, "/")
          if (parts[1] != "") print parts[1]
        }
      }' >> "$active_file"
    then
      log "open-file scan failed — skip system temp cleanup"
      rm -f "$active_file" "$snapshot_file"
      return
    fi
  else
    log "lsof unavailable — skip system temp cleanup"
    rm -f "$active_file" "$snapshot_file" "$recent_file"
    return
  fi

  awk -v prefix="$root/" '{
    text = $0
    while ((pos = index(text, prefix)) > 0) {
      text = substr(text, pos + length(prefix))
      split(text, parts, "/")
      if (parts[1] != "") print parts[1]
      text = substr(text, length(parts[1]) + 1)
    }
  }' "$snapshot_file" >> "$active_file"

  if ! find "$root" -mindepth 1 \
    \( -name 'com.apple.*' -o -name '.com.apple.*' \) -prune -o \
    \( -name TemporaryItems -print0 -prune \) -o \
    -mtime "-$MAX_AGE_DAYS" -print0 > "$recent_file" 2>/dev/null; then
    log "recent-file scan failed — skip system temp cleanup"
    rm -f "$active_file" "$snapshot_file" "$recent_file"
    return
  fi
  while IFS= read -r -d '' path; do
    relative="${path#"$root"/}"
    name="${relative%%/*}"
    [ -n "$name" ] && echo "$name" >> "$active_file"
  done < "$recent_file"
  sort -u "$active_file" -o "$active_file"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    exclude+=( ! -path "$root/$name" ! -path "$root/$name/*" )
  done < "$active_file"

  candidate_count="$(find "$root" -mindepth 1 -maxdepth 1 -mtime "+$((MAX_AGE_DAYS - 1))" \
    ! -name 'com.apple.*' ! -name '.com.apple.*' ! -name TemporaryItems ! -empty \
    "${exclude[@]}" -print 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ -n "$candidate_count" ] || candidate_count=0
  log "remove $candidate_count inactive system temp entries older than $MAX_AGE_DAYS day(s): $root"
  find "$root" -mindepth 1 -maxdepth 1 -mtime "+$((MAX_AGE_DAYS - 1))" \
    ! -name 'com.apple.*' ! -name '.com.apple.*' ! -name TemporaryItems ! -empty \
    "${exclude[@]}" -exec rm -rf {} + 2>/dev/null || log "could not fully clean system temp: $root"
  system_removed=$((system_removed + candidate_count))
  rm -f "$active_file" "$snapshot_file" "$recent_file"
}

if [ -n "$SYSTEM_TMP_ROOT" ] && [ "${SYSTEM_TMP_ROOT%/}" != "${TMP_ROOT%/}" ]; then
  clean_system_temp "$SYSTEM_TMP_ROOT"
fi

# These directories contain disposable scratch data. Keep recent items to
# protect active and resumable tasks. Do not touch task history or profiles.
for cache_root in "$HOME/.codex/.tmp" "$HOME/.agent-browser/tmp"; do
  [ -d "$cache_root" ] || continue
  find "$cache_root" -mindepth 1 -mtime +6 -depth -delete 2>/dev/null || true
done

log "done: removed $removed agent artifacts and $system_removed system temp entries, active kept $kept"
