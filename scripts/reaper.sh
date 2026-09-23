#!/usr/bin/env bash
#
# reaper.sh — single entry point for the optional machine-hygiene reapers.
# It is intended for macOS LaunchAgents. Each concern has its own cadence,
# so fast checks do not force expensive disk and Docker scans to run often.
#
# Why two lanes: the checks fall into two groups with very different costs.
# A single serial job let a 45-minute storage cleanup block every memory
# check behind it while swap filled. The fast lane now runs by itself every
# minute. The slow lane runs every five minutes, and a timeout bounds each
# step, so a hung step cannot block its lane.
#
# fast lane (launchd every 60s)
#   * Stale dev servers — every run. Closes idle dev-server trees that are
#     unattended, over a day old, in a deleted worktree, or under swap
#     pressure. See reap-stale-dev-servers.sh.
#   * Idle language servers — every run. Closes idle or runaway TypeScript
#     language servers left by agent sessions.
#   * Chrome tab cap — every run. Holds the personal Chrome under its cap.
#   * Next.js, headless Chrome, ChatGPT helpers, Vitest — every 5 minutes.
#     These scan more slowly and were tuned for a 5-minute cadence.
#
# slow lane (launchd every 300s)
#   * agent-browser — hourly. Reclaims RAM/CPU from idle daemons via 2
#     consecutive idle-CPU-rate sightings ~2h apart.
#   * local dev services — hourly. Reclaims stale, idle Inngest, Hatchet, SST,
#     Vite, and Turbo dev processes after two idle observations.
#   * workspace storage cleanup — every 6h. Disk fills slowly; more frequent
#     scans add I/O without helping.
#   * agent artifacts — daily. Removes stale, known temporary directories only.
#   * docker volumes/images — daily. Same reasoning, even slower to refill.
#   * Node and tooling caches — weekly. Package stores refill slowly.
#
# Each gated check keeps its cadence through its own last-run marker file.
# Settings come from the environment and from $DEV_HYGIENE_STATE_DIR/config.env.
# DEV_HYGIENE_OVERRIDE_DIR, when set, is searched first for each sub-script,
# so a machine can keep locally tuned copies of individual reapers.
#
# This file adds no deletion or kill logic of its own beyond stopping a step
# that exceeds its timeout. It only decides when to invoke sibling scripts.
#
# Usage:
#   reaper.sh [--lane fast|slow|all]   # default: all (both lanes, in order)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYGIENE_DIR="${DEV_HYGIENE_STATE_DIR:-$HOME/.dev-hygiene}"
# Machine settings live in one env file, so tuning a threshold needs no plist
# edit. Every variable it sets is exported to the sub-scripts.
if [ -f "$HYGIENE_DIR/config.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$HYGIENE_DIR/config.env"
  set +a
fi
OVERRIDE_DIR="${DEV_HYGIENE_OVERRIDE_DIR:-}"
FAST_STEP_TIMEOUT="${DEV_HYGIENE_FAST_STEP_TIMEOUT_SEC:-180}"
SLOW_STEP_TIMEOUT="${DEV_HYGIENE_SLOW_STEP_TIMEOUT_SEC:-1800}"
LOG_MAX_BYTES="${DEV_HYGIENE_LOG_MAX_BYTES:-5242880}"
LOG_FILE="${DEV_HYGIENE_LOG_FILE:-}"
mkdir -p "$HYGIENE_DIR"

LANE=all
while [ $# -gt 0 ]; do
  case "$1" in
    --lane) LANE="${2:-all}"; shift ;;
  esac
  shift
done
case "$LANE" in fast|slow|all) ;; *) echo "unknown lane: $LANE" >&2; exit 2 ;; esac

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Keep launchd's log bounded. launchd holds the file open for appending, so
# copy and truncate in place instead of renaming it.
if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] && \
   [ "$(stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
  cp -f "$LOG_FILE" "$LOG_FILE.1" && : > "$LOG_FILE"
fi

# One run per lane at a time, also across manual runs.
LOCK="$HYGIENE_DIR/lane-$LANE.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    log "lane $LANE already running (pid $holder) — skipping"
    exit 0
  fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

script_path() {
  if [ -n "$OVERRIDE_DIR" ] && [ -f "$OVERRIDE_DIR/$1" ]; then
    echo "$OVERRIDE_DIR/$1"
  else
    echo "$SCRIPT_DIR/$1"
  fi
}

kill_descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do kill_descendants "$child"; done
  kill -TERM "$1" 2>/dev/null || true
}

# run_step <label> <script> <timeout-sec> — run a sub-script with indented
# output. Stop it and its children when it exceeds the timeout.
run_step() {
  local label="$1" path waited=0 pid
  path="$(script_path "$2")"
  log "== $label =="
  if [ ! -f "$path" ]; then
    log "  $2 not found — skipping"
    return
  fi
  bash "$path" > >(sed 's/^/  /') 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$3" ]; then
      log "  TIMEOUT after ${3}s — stopping $2"
      kill_descendants "$pid"
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
}

# due <marker-file> <interval-seconds> — true (and touches the marker) once
# at least <interval> seconds have passed since the marker was last touched.
due() {
  local marker="$1" interval="$2" now last
  now="$(date +%s)"
  last="$(cat "$marker" 2>/dev/null || echo 0)"
  if [ $(( now - last )) -ge "$interval" ]; then
    echo "$now" > "$marker"
    return 0
  fi
  return 1
}

# gated <marker> <interval> <label> <script> <timeout>
gated() {
  if due "$HYGIENE_DIR/$1" "$2"; then
    run_step "$3" "$4" "$5"
  else
    log "-- $3: not due yet --"
  fi
}

fast_lane() {
  run_step "stale dev-server check (every run)" reap-stale-dev-servers.sh "$FAST_STEP_TIMEOUT"
  run_step "idle language-server check (every run)" reap-idle-lsp.sh "$FAST_STEP_TIMEOUT"
  run_step "Chrome tab memory cap (every run)" reap-chrome-tab-cap.sh "$FAST_STEP_TIMEOUT"
  if due "$HYGIENE_DIR/.last-fast-5min" 270; then
    run_step "Next.js memory-pressure check (5 min)" reap-next-jobs.sh "$FAST_STEP_TIMEOUT"
    run_step "headless Chrome orphan/resource check (5 min)" reap-runaway-chrome.sh "$FAST_STEP_TIMEOUT"
    run_step "orphaned ChatGPT helper check (5 min)" reap-orphaned-chatgpt-helpers.sh "$FAST_STEP_TIMEOUT"
    run_step "Vitest runaway-run check (5 min)" reap-runaway-vitest.sh "$FAST_STEP_TIMEOUT"
  fi
}

slow_lane() {
  gated .last-agent-browser 3600 "agent-browser idle-daemon check (hourly)" reap-idle-agent-browser.sh "$SLOW_STEP_TIMEOUT"
  gated .last-dev-services 3600 "local dev-service check (hourly)" reap-dev-services.sh "$SLOW_STEP_TIMEOUT"
  gated .last-storage 21600 "workspace storage cleanup (every 6h)" reap-storage.sh "$SLOW_STEP_TIMEOUT"
  gated .last-agent-artifacts 86400 "stale agent artifact cleanup (daily)" reap-agent-artifacts.sh "$SLOW_STEP_TIMEOUT"
  gated .last-docker 86400 "docker volume/image cleanup (daily)" reap-docker-volumes.sh "$SLOW_STEP_TIMEOUT"
  gated .last-node-tooling 604800 "Node and tooling cache cleanup (weekly)" reap-node-tooling.sh "$SLOW_STEP_TIMEOUT"
}

case "$LANE" in
  fast) fast_lane ;;
  slow) slow_lane ;;
  all) fast_lane; slow_lane ;;
esac

log "done ($LANE lane)"
