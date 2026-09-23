#!/usr/bin/env bash
#
# install.sh — copy the reapers to a stable path and load both launchd lanes.
#
# launchd runs a copy under $DEV_HYGIENE_STATE_DIR/current, not this checkout,
# so switching branches here never changes what runs. Run this again after
# pulling to update the copy.
#
#   <prefix>.fast   reaper.sh --lane fast, every 60s,  log reaper-fast.log
#   <prefix>        reaper.sh --lane slow, every 300s, log reaper.log
#
# A lane that is in the middle of a run is not reloaded, because unloading a
# job stops it. Pass --force to reload it anyway.
#
# Usage:
#   DEV_HYGIENE_LABEL_PREFIX=com.you.dev-hygiene-reaper scripts/install.sh [--force]
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${DEV_HYGIENE_STATE_DIR:-$HOME/.dev-hygiene}"
DEST="$STATE_DIR/current"
PREFIX="${DEV_HYGIENE_LABEL_PREFIX:-com.example.dev-hygiene-reaper}"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$DEST" "$AGENTS"
rsync -a --delete --exclude install.sh "$SRC/" "$DEST/"
echo "copied scripts to $DEST"

write_plist() {
  local label="$1" lane="$2" interval="$3" log="$4"
  cat > "$AGENTS/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DEST/reaper.sh</string>
    <string>--lane</string>
    <string>$lane</string>
  </array>
  <key>StartInterval</key><integer>$interval</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>DEV_HYGIENE_STATE_DIR</key><string>$STATE_DIR</string>
    <key>DEV_HYGIENE_LOG_FILE</key><string>$log</string>
  </dict>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
}

load() {
  local label="$1"
  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    if [ "$FORCE" -eq 0 ] && launchctl print "$DOMAIN/$label" | grep -q '^\s*pid = '; then
      echo "$label is mid-run — plist updated, reload skipped (rerun later or pass --force)"
      return
    fi
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  fi
  launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
  echo "loaded $label"
}

write_plist "$PREFIX.fast" fast 60 "$STATE_DIR/reaper-fast.log"
write_plist "$PREFIX" slow 300 "$STATE_DIR/reaper.log"
load "$PREFIX.fast"
load "$PREFIX"
