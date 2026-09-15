#!/usr/bin/env bash
#
# reaper.sh — single entry point for the optional machine-hygiene reapers.
# It is intended for a macOS LaunchAgent. Each concern has its own cadence,
# so fast checks do not force expensive disk and Docker scans to run often.
#
# Why gate each concern: the checks have different costs and do not share a
# useful interval.
#   * Next.js — every invocation (~5min). On serious system swap pressure, it
#     closes Next first. It also closes one Next process tree that exceeds its
#     RSS ceiling. A dev server is restartable; the rest of the desktop is not.
#   * ChatGPT helpers — every invocation (~5min). Reaps only confirmed,
#     orphaned renderers/services; the main app and its live children are out
#     of scope.
#   * Vitest — every invocation (~5min). Tests are disposable on this machine,
#     so a run gets a 10-minute ceiling and memory/swap pressure reaps it
#     immediately. This catches hung runners, not just their workers.
#   * agent-browser — hourly. Reclaims RAM/CPU from idle daemons via 2
#     consecutive idle-CPU-rate sightings ~2h apart.
#   * local dev services — hourly. Reclaims stale, idle Inngest, Hatchet, SST,
#     Vite, and Turbo dev processes after two idle observations.
#   * workspace storage cleanup — every 6h. Disk fills slowly; more frequent
#     scans add I/O without helping.
#   * agent artifacts — daily. Removes stale, known temporary directories only.
#   * docker volumes/images — daily. Same reasoning, even slower to refill.
#   * Node and tooling caches — weekly. Package stores refill slowly.
# Running every expensive check on the tightest (5min) interval would waste CPU/IO
# re-scanning worktrees and Docker state almost every time with nothing new
# to find. This script keeps ONE launchd job but preserves each check's
# original real-world cadence via its own last-run marker file.
#
# This file adds no deletion or kill logic. It only decides when to invoke
# sibling scripts. Read each script before enabling it.
#
# Usage:
#   reaper.sh   # runs the vitest check every time; gates the other three by
#               # their own last-run marker under ~/.dev-hygiene/
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYGIENE_DIR="${DEV_HYGIENE_STATE_DIR:-$HOME/.dev-hygiene}"
mkdir -p "$HYGIENE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "== Next.js memory-pressure check (every run; Next yields first) =="
if [ -f "$SCRIPT_DIR/reap-next-jobs.sh" ]; then
  bash "$SCRIPT_DIR/reap-next-jobs.sh" 2>&1 | sed 's/^/  /'
else
  log "  reap-next-jobs.sh not found — skipping"
fi

log "== orphaned ChatGPT helper check (every run) =="
if [ -f "$SCRIPT_DIR/reap-orphaned-chatgpt-helpers.sh" ]; then
  bash "$SCRIPT_DIR/reap-orphaned-chatgpt-helpers.sh" 2>&1 | sed 's/^/  /'
else
  log "  reap-orphaned-chatgpt-helpers.sh not found — skipping"
fi

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

log "== Vitest runaway-run check (every run) =="
if [ -f "$SCRIPT_DIR/reap-runaway-vitest.sh" ]; then
  bash "$SCRIPT_DIR/reap-runaway-vitest.sh" 2>&1 | sed 's/^/  /'
else
  log "  reap-runaway-vitest.sh not found — skipping"
fi

if due "$HYGIENE_DIR/.last-agent-browser" 3600; then
  log "== agent-browser idle-daemon check (hourly) =="
  if [ -f "$SCRIPT_DIR/reap-idle-agent-browser.sh" ]; then
    bash "$SCRIPT_DIR/reap-idle-agent-browser.sh" 2>&1 | sed 's/^/  /'
  else
    log "  reap-idle-daemons.sh not found — skipping"
  fi
else
  log "-- agent-browser: not due yet --"
fi

if due "$HYGIENE_DIR/.last-dev-services" 3600; then
  log "== local dev-service check (hourly) =="
  if [ -f "$SCRIPT_DIR/reap-dev-services.sh" ]; then
    bash "$SCRIPT_DIR/reap-dev-services.sh" 2>&1 | sed 's/^/  /'
  else
    log "  reap-dev-services.sh not found — skipping"
  fi
else
  log "-- dev services: not due yet --"
fi

if due "$HYGIENE_DIR/.last-storage" 21600; then
  log "== workspace storage cleanup (every 6h) =="
  if [ -f "$SCRIPT_DIR/reap-storage.sh" ]; then
    bash "$SCRIPT_DIR/reap-storage.sh" 2>&1 | sed 's/^/  /'
  else
    log "  reap-storage.sh not found — skipping"
  fi
else
  log "-- storage: not due yet --"
fi

if due "$HYGIENE_DIR/.last-agent-artifacts" 86400; then
  log "== stale agent artifact cleanup (daily) =="
  if [ -f "$SCRIPT_DIR/reap-agent-artifacts.sh" ]; then
    bash "$SCRIPT_DIR/reap-agent-artifacts.sh" 2>&1 | sed 's/^/  /'
  else
    log "  reap-agent-artifacts.sh not found — skipping"
  fi
else
  log "-- agent artifacts: not due yet --"
fi

if due "$HYGIENE_DIR/.last-docker" 86400; then
  log "== docker volume/image cleanup (daily) =="
  if [ -f "$SCRIPT_DIR/reap-docker-volumes.sh" ]; then
    bash "$SCRIPT_DIR/reap-docker-volumes.sh" 2>&1 | sed 's/^/  /'
  else
    log "  reap-docker-volumes.sh not found — skipping"
  fi
else
  log "-- docker: not due yet --"
fi

if due "$HYGIENE_DIR/.last-node-tooling" 604800; then
  log "== Node and tooling cache cleanup (weekly) =="
  if [ -f "$SCRIPT_DIR/reap-node-tooling.sh" ]; then
    bash "$SCRIPT_DIR/reap-node-tooling.sh" 2>&1 | sed 's/^/  /'
  else
    log "  reap-node-tooling.sh not found — skipping"
  fi
else
  log "-- Node and tooling caches: not due yet --"
fi

log "done"
