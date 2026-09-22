#!/usr/bin/env bash
# Reclaim rebuildable caches, old dependencies, and stale clean worktrees.
# Set DEV_HYGIENE_REPOS to a space-separated list of primary Git checkouts.
set -uo pipefail

REPOS="${DEV_HYGIENE_REPOS:-}"
STALE_DAYS="${DEV_HYGIENE_STALE_DAYS:-3}"
STRIP_HOURS="${DEV_HYGIENE_STRIP_HOURS:-48}"
STATE_DIR="${DEV_HYGIENE_STATE_DIR:-$HOME/.dev-hygiene}"
LOCK_DIR="$STATE_DIR/reap-storage.lock"
NOW="$(date +%s)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

case "$STALE_DAYS:$STRIP_HOURS" in
  *[!0-9:]*) log "storage age settings must be non-negative integers — skip"; exit 0 ;;
esac

if [ -z "$REPOS" ]; then
  log "DEV_HYGIENE_REPOS is not set — skip workspace storage cleanup"
  exit 0
fi

mkdir -p "$STATE_DIR"
if [ -d "$LOCK_DIR" ]; then
  lock_age=$((NOW - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)))
  [ "$lock_age" -gt 21600 ] && rmdir "$LOCK_DIR" 2>/dev/null || true
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "already running — skip"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

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

clean_caches() {
  local root="$1" path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    log "remove cache $(human "$path"): $path"
    rm -rf "$path"
  done < <(find "$root" -name node_modules -prune -o \
    \( -name .next -o -name .turbo -o -name .vite -o -name .vite-temp \
       -o -name dist -o -name coverage \) -type d -print 2>/dev/null)

  for path in "$root/.sst/dist" "$root/.sst/artifacts"; do
    [ -d "$path" ] || continue
    log "remove cache $(human "$path"): $path"
    rm -rf "$path"
  done
}

clean_worktree() {
  local main="$1" worktree="$2" modified mtime age
  if is_active "$worktree"; then
    log "active — keep: $worktree"
    return
  fi

  clean_caches "$worktree"
  mtime="$(stat -f %m "$worktree" 2>/dev/null || echo "$NOW")"
  age=$((NOW - mtime))
  if [ -d "$worktree/node_modules" ] && [ "$age" -ge $((STRIP_HOURS * 3600)) ]; then
    log "remove dependencies $(human "$worktree/node_modules"): $worktree/node_modules"
    rm -rf "$worktree/node_modules"
  fi

  modified="$(git -C "$worktree" status --porcelain 2>/dev/null | head -1)"
  if [ -z "$modified" ] && [ "$age" -ge $((STALE_DAYS * 86400)) ]; then
    log "remove stale clean worktree: $worktree"
    git -C "$main" worktree remove --force "$worktree" || log "could not remove: $worktree"
  fi
}

for repo in $REPOS; do
  [ -d "$repo" ] || { log "missing repo: $repo"; continue; }
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { log "not a Git repo: $repo"; continue; }
  main="$(git -C "$repo" worktree list --porcelain | awk '/^worktree / { print $2; exit }')"
  [ -n "$main" ] || continue

  if is_active "$main"; then
    log "active — keep caches: $main"
  else
    clean_caches "$main"
  fi

  while IFS= read -r worktree; do
    [ -d "$worktree" ] || continue
    [ "$worktree" = "$main" ] && continue
    clean_worktree "$main" "$worktree"
  done < <(git -C "$main" worktree list --porcelain | awk '/^worktree / { print $2 }')
  git -C "$main" worktree prune
done

log "done"
