#!/usr/bin/env bash
#
# reap-orphaned-chatgpt-helpers.sh — remove abandoned ChatGPT helper processes.
#
# This is intentionally NOT an app restart or a memory-limit enforcer. It
# targets only a narrow leak signature: a ChatGPT renderer, service, or local
# code helper that has been re-parented to launchd (PPID 1). Such a process has
# outlived the app process that created it and cannot serve a live ChatGPT
# window. Normal ChatGPT renderers/services always retain a non-root parent and
# are never touched here.
#
# Safety:
#   * never signals the ChatGPT main process;
#   * only accepts executables inside the installed ChatGPT app bundle;
#   * only accepts known work helpers, not the updater/crash reporter; and
#   * requires two consecutive sightings after one hour before SIGTERM.
#
# Usage:
#   reap-orphaned-chatgpt-helpers.sh
#   reap-orphaned-chatgpt-helpers.sh --dry-run
set -euo pipefail

AGE_MIN_SEC="${CHATGPT_ORPHAN_REAP_AGE_MIN_SEC:-3600}"
CONFIRM_RUNS="${CHATGPT_ORPHAN_REAP_CONFIRM_RUNS:-2}"
STATE_DIR="$HOME/.dev-hygiene"
STATE_FILE="$STATE_DIR/chatgpt-orphan-reaper-state"
NEW_STATE="$STATE_DIR/chatgpt-orphan-reaper-state.new"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

mkdir -p "$STATE_DIR"
: > "$NEW_STATE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

etime_to_sec() {
  local value="$1" days=0 rest hh=0 mm ss
  case "$value" in *-*) days="${value%%-*}"; rest="${value#*-}";; *) rest="$value";; esac
  local IFS=:
  # shellcheck disable=SC2086
  set -- $rest
  case $# in
    3) hh="$1"; mm="$2"; ss="$3";;
    2) mm="$1"; ss="$2";;
    *) echo 0; return;;
  esac
  echo $(( 10#$days*86400 + 10#$hh*3600 + 10#$mm*60 + 10#$ss ))
}

prev_confirm_for() { awk -v process="$1" '$1==process {print $2}' "$STATE_FILE" 2>/dev/null; }

reaped=0 kept=0
while read -r pid ppid etime cmd; do
  [ "$ppid" = "1" ] || continue

  # This excludes ChatGPT itself, Sparkle/updater, crash reporting, and any
  # process outside the app bundle. It intentionally recognizes just helpers
  # that should always die with their owning app.
  case "$cmd" in
    /Applications/ChatGPT.app/Contents/*'Codex (Renderer)'*|\
    /Applications/ChatGPT.app/Contents/*'Codex (Service)'*|\
    /Applications/ChatGPT.app/Contents/Resources/codex\ *|\
    /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host*|\
    /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl*) ;;
    *) continue;;
  esac

  age_sec="$(etime_to_sec "$etime")"
  if [ "$age_sec" -lt "$AGE_MIN_SEC" ]; then
    kept=$(( kept + 1 ))
    continue
  fi

  previous="$(prev_confirm_for "$pid")"
  confirm=$(( ${previous:-0} + 1 ))
  if [ "$confirm" -lt "$CONFIRM_RUNS" ]; then
    echo "$pid $confirm" >> "$NEW_STATE"
    log "SEEN orphaned ChatGPT helper $pid (age ${age_sec}s), confirm ${confirm}/${CONFIRM_RUNS} — not yet reaping"
    kept=$(( kept + 1 ))
    continue
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "$pid ${previous:-0}" >> "$NEW_STATE"
    log "WOULD REAP orphaned ChatGPT helper $pid (age ${age_sec}s)"
  else
    kill -TERM "$pid" 2>/dev/null || true
    log "REAPED orphaned ChatGPT helper $pid (age ${age_sec}s)"
  fi
  reaped=$(( reaped + 1 ))
done < <(ps -axo pid=,ppid=,etime=,command=)

mv -f "$NEW_STATE" "$STATE_FILE"
suffix=""; [ "$DRY_RUN" = 1 ] && suffix=" (dry-run)"
log "done: ${reaped} reaped, ${kept} kept${suffix}"
