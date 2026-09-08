#!/usr/bin/env bash
# Reclaim rebuildable caches and stale clean linked worktrees.
# Set DEV_HYGIENE_REPOS to a space-separated list of primary Git checkouts.
# The script does nothing until you explicitly configure this list. A worktree
# must be clean and inactive for seven days before this script removes it. Its
# branch remains in Git.
set -uo pipefail

REPOS="${DEV_HYGIENE_REPOS:-}"
STALE_DAYS="${DEV_HYGIENE_STALE_DAYS:-7}"
NOW="$(date +%s)"
MAX_AGE=$((STALE_DAYS * 86400))

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

clean_caches() {
  local root="$1" path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -rf "$path"
    log "removed cache: $path"
  done < <(find "$root" -name node_modules -prune -o \
    \( -name .next -o -name .turbo -o -name .vite -o -name dist \) -type d -print 2>/dev/null)
}

if [ -z "$REPOS" ]; then
  log "DEV_HYGIENE_REPOS is not set — skipping workspace storage cleanup"
  exit 0
fi

for repo in $REPOS; do
  [ -d "$repo" ] || { log "missing repo: $repo"; continue; }
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { log "not a Git repo: $repo"; continue; }
  main="$(git -C "$repo" worktree list --porcelain | awk '/^worktree / { print $2; exit }')"
  [ -n "$main" ] || continue

  log "cleaning rebuildable caches in $main"
  clean_caches "$main"
  while IFS= read -r worktree; do
    [ -d "$worktree" ] || continue
    [ "$worktree" = "$main" ] && continue
    clean_caches "$worktree"

    modified="$(git -C "$worktree" status --porcelain 2>/dev/null | head -1)"
    mtime="$(stat -f %m "$worktree" 2>/dev/null || echo "$NOW")"
    age=$((NOW - mtime))
    if [ -z "$modified" ] && [ "$age" -ge "$MAX_AGE" ]; then
      log "removing stale clean worktree: $worktree"
      git -C "$main" worktree remove --force "$worktree" || log "could not remove: $worktree"
    fi
  done < <(git -C "$main" worktree list --porcelain | awk '/^worktree / { print $2 }')
  git -C "$main" worktree prune
done
