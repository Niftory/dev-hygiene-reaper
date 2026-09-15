#!/usr/bin/env bash
#
# reap-docker-volumes.sh — reclaim disk from orphaned Docker/OrbStack state:
# anonymous unattached volumes, orphaned agent-project volumes, stopped
# containers, and unused images. Fully unattended, every run.
#
# WHY: OrbStack's VM disk (Library/Group Containers/HUAQ24HBR6.dev.orbstack/
# data/data.img.raw) reached 178GB on 2026-07-31 — 161.6GB of it sitting in
# 148 ANONYMOUS, unattached volumes nothing referenced anymore, accumulated
# from years of ephemeral container runs (local test containers, one-off
# `docker run`s) that never got a matching `docker volume rm`. The 16 NAMED
# volumes (this repo's local Timescale/Neon/Redis dev DBs, Hatchet CLI state,
# an old devcontainer setup) totalled only ~7GB combined and were never the
# problem — pruning just the anonymous ones reclaimed essentially all of it
# (178G -> 34G on disk) with zero risk to any real data.
#
# SAFETY:
#   * It removes volumes whose name is a bare 64-char hex ID — Docker's
#     auto-generated anonymous-volume naming, which no meaningful named
#     volume (this repo's dev DBs, anything from a `-v name:path` mount) can
#     ever collide with.
#   * It removes a named volume only when Docker marks it dangling, its Compose
#     project has a known agent prefix, and that project directory is missing.
#     Base project volumes and volumes for existing directories remain.
#   * Only removes volumes Docker itself reports as dangling (not referenced
#     by ANY container, running or stopped). `docker volume rm` hard-refuses
#     to remove a volume an existing container still references, so even a
#     stopped-but-not-yet-removed container's volume survives regardless.
#   * Also runs `docker container prune` (STOPPED containers only, never a
#     running one) and `docker image prune -a` (images not used by any
#     existing container — re-pullable/rebuildable on demand) and
#     `docker builder prune` (build cache layers nothing references). All
#     standard, fully reversible Docker hygiene — nothing here is unique,
#     non-regenerable data.
#   * If the daemon isn't running or is unresponsive, this skips entirely
#     rather than hang — `docker version` has to answer within
#     DAEMON_PROBE_TIMEOUT seconds (default 15) or the whole run aborts.
#     Seen for real on 2026-07-31: the daemon can wedge after sitting idle
#     and hang a plain `docker system df` for 10+ minutes; an unattended job
#     must never block on that. No `timeout`/`gtimeout` binary exists on this
#     Mac, so the bound is implemented by hand (background + poll + kill).
#   * A lock file prevents two runs overlapping; a lock older than 1h is
#     treated as stale (crashed run) and cleared.
#
# Usage:
#   reap-docker-volumes.sh   # apply, log to stdout
set -uo pipefail

DAEMON_PROBE_TIMEOUT="${DOCKER_REAP_PROBE_TIMEOUT:-15}"
PROJECTS_ROOT="${DEV_HYGIENE_PROJECTS_ROOT:-${SIFT_PROJECTS_ROOT:-$HOME/Projects}}"
STATE_DIR="${DEV_HYGIENE_STATE_DIR:-$HOME/.dev-hygiene}"
LOCK_DIR="$STATE_DIR/reap-docker.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

mkdir -p "$STATE_DIR"

if [ -d "$LOCK_DIR" ]; then
  lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
  if [ "$lock_age" -gt 3600 ]; then
    log "stale lock (${lock_age}s old) — clearing"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "already running (lock held) — skipping this run"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

command -v docker >/dev/null 2>&1 || { log "docker CLI not found — skipping"; exit 0; }

# Bound any docker call by hand (no timeout/gtimeout on this Mac): run it in
# the background, poll, kill past the deadline.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
  done
  wait "$pid"
}

if ! run_with_timeout "$DAEMON_PROBE_TIMEOUT" docker version >/dev/null 2>&1; then
  log "docker daemon not responsive within ${DAEMON_PROBE_TIMEOUT}s — skipping this run"
  exit 0
fi

log "== docker daemon responsive =="

log "-- anonymous unattached volumes --"
# Portable across the bash 3.2 that ships on macOS (launchd invokes /bin/bash
# directly, not via the shebang) — no mapfile, no arrays, just word-splitting
# a space-separated string. Safe here: volume names are bare hex, no spaces.
anon_count=0
anon_volumes=""
while IFS= read -r v; do
  [ -z "$v" ] && continue
  anon_volumes="$anon_volumes $v"
  anon_count=$((anon_count + 1))
done < <(docker volume ls -f dangling=true --format '{{.Name}}' 2>/dev/null | grep -E '^[0-9a-f]{60,}$')

if [ "$anon_count" -eq 0 ]; then
  log "  none to remove"
else
  log "  removing $anon_count anonymous volumes"
  # shellcheck disable=SC2086
  docker volume rm $anon_volumes >/dev/null 2>&1 || log "  (some removals failed, likely still referenced — left in place)"
fi

log "-- stopped containers --"
docker container prune -f 2>&1 | sed 's/^/  /'

log "-- orphaned named agent-project volumes --"
while IFS= read -r volume; do
  [ -n "$volume" ] || continue
  project="$(docker volume inspect "$volume" \
    --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
  case "$project" in
    agent-*|crm-agent-*|sift-agent-*|sift-core-*|sift-crm-*) ;;
    *) continue ;;
  esac
  [ -d "$PROJECTS_ROOT/$project" ] && continue
  log "  removing $volume (missing project: $project)"
  docker volume rm "$volume" >/dev/null 2>&1 || log "  keep $volume: removal failed"
done < <(docker volume ls -f dangling=true --format '{{.Name}}' 2>/dev/null)

log "-- unused images --"
docker image prune -a -f 2>&1 | sed 's/^/  /'

log "-- unreferenced build cache --"
docker builder prune -f 2>&1 | sed 's/^/  /'

log "done"
