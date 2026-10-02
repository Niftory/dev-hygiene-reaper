#!/usr/bin/env bash
# Reclaim rebuildable caches, old dependencies, and stale clean worktrees.
# Scans Git checkouts under DEV_HYGIENE_PROJECTS_ROOT and optional extra repos.
set -uo pipefail

REPOS="${DEV_HYGIENE_REPOS:-}"
PROJECTS_ROOT="${DEV_HYGIENE_PROJECTS_ROOT:-$HOME/Projects}"
STALE_DAYS="${DEV_HYGIENE_STALE_DAYS:-3}"
STRIP_HOURS="${DEV_HYGIENE_STRIP_HOURS:-24}"
EMPTY_TRASH="${DEV_HYGIENE_EMPTY_TRASH:-0}"
STATE_DIR="${DEV_HYGIENE_STATE_DIR:-$HOME/.dev-hygiene}"
LOCK_DIR="$STATE_DIR/reap-storage.lock"
NOW="$(date +%s)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

case "$STALE_DAYS:$STRIP_HOURS" in
  *[!0-9:]*) log "storage age settings must be non-negative integers — skip"; exit 0 ;;
esac

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

has_live_web_dev_server() {
  local root="$1" command
  while IFS= read -r command; do
    case "$command" in
      *"$root"*)
        case "$command" in
          *'/.next/'*|*'/node_modules/next/'*|*'/node_modules/.bin/next'*|*' next dev'*|\
          *'/node_modules/vite/'*|*'/node_modules/.bin/vite'*|*' vite dev'*) return 0 ;;
        esac
        ;;
    esac
  done <<< "$process_snapshot"
  return 1
}

clean_next_caches() {
  local root="$1" path
  if has_live_web_dev_server "$root"; then
    log "live web dev server — keep .next: $root"
    return
  fi

  while IFS= read -r -d '' path; do
    log "remove inactive Next output: $path"
    rm -rf "$path"
  done < <(find "$root" -name .git -prune -o -name node_modules -prune -o \
    -name .next -type d -print0 2>/dev/null)
}

clean_caches() {
  local root="$1" path
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    log "remove generated data: $path"
    rm -rf "$path"
  done < <(find "$root" -name .git -prune -o -name node_modules -prune -o \
    \( -name .next -o -name .turbo -o -name .vite -o -name .vite-temp \
       -o -name .vercel -o -name .parcel-cache -o -name .cache \
       -o -name .output -o -name dist -o -name out \
       -o -name coverage -o -name .nyc_output -o -name playwright-report \
       -o -name storybook-static -o -name target -o -name .pytest_cache \
       -o -name .mypy_cache -o -name .ruff_cache \) -type d -print0 2>/dev/null)

  for path in "$root/.sst/dist" "$root/.sst/artifacts"; do
    [ -d "$path" ] || continue
    log "remove generated data: $path"
    rm -rf "$path"
  done
}

clean_dependencies() {
  local root="$1" mtime age path

  mtime="$(stat -f %m "$root" 2>/dev/null || echo "$NOW")"
  age=$((NOW - mtime))
  [ "$age" -ge $((STRIP_HOURS * 3600)) ] || return

  while IFS= read -r -d '' path; do
    log "remove stale dependencies: $path"
    rm -rf "$path"
  done < <(find "$root" -name .git -prune -o -name node_modules -type d -print0 2>/dev/null)
}

clean_worktree() {
  local main="$1" worktree="$2" modified mtime age
  if is_active "$worktree"; then
    log "active — keep dependencies: $worktree"
    clean_next_caches "$worktree"
    return
  fi

  mtime="$(stat -f %m "$worktree" 2>/dev/null || echo "$NOW")"
  age=$((NOW - mtime))
  clean_caches "$worktree"
  clean_dependencies "$worktree"

  if [ "$age" -ge $((STALE_DAYS * 86400)) ]; then
    modified="$(git -C "$worktree" status --porcelain 2>/dev/null | head -1)"
    if [ -z "$modified" ]; then
      log "remove stale clean worktree: $worktree"
      git -C "$main" worktree remove --force "$worktree" || log "could not remove: $worktree"
    fi
  fi
}

REPO_LIST="$STATE_DIR/storage-repos.$$"
SEEN_LIST="$STATE_DIR/storage-seen.$$"
: > "$REPO_LIST"
: > "$SEEN_LIST"
trap 'rm -f "$REPO_LIST" "$SEEN_LIST"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

add_repo() {
  local repo="$1" common
  [ -d "$repo" ] || return
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return
  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)"
  case "$common" in
    /*) ;;
    *) common="$repo/$common" ;;
  esac
  common="$(cd "$common" 2>/dev/null && pwd -P)" || return
  grep -Fqx "$common" "$SEEN_LIST" && return
  echo "$common" >> "$SEEN_LIST"
  echo "$repo" >> "$REPO_LIST"
}

for repo in $REPOS; do add_repo "$repo"; done
if [ -d "$PROJECTS_ROOT" ]; then
  while IFS= read -r -d '' repo; do add_repo "$repo"; done \
    < <(find "$PROJECTS_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

if [ ! -s "$REPO_LIST" ]; then
  log "no Git repositories found under configured paths — skip workspace cleanup"
fi

while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  main="$(git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p' | head -1)"
  [ -n "$main" ] || continue

  if is_active "$main"; then
    log "active — keep dependencies: $main"
    clean_next_caches "$main"
  else
    clean_caches "$main"
    clean_dependencies "$main"
  fi

  while IFS= read -r worktree; do
    [ -d "$worktree" ] || continue
    [ "$worktree" = "$main" ] && continue
    clean_worktree "$main" "$worktree"
  done < <(git -C "$main" worktree list --porcelain | sed -n 's/^worktree //p')
  git -C "$main" worktree prune
done < "$REPO_LIST"

if [ "$EMPTY_TRASH" = 1 ]; then
  if command -v osascript >/dev/null 2>&1; then
    trash_items="$(osascript -e 'tell application "Finder" to count items in trash' 2>/dev/null || true)"
    case "$trash_items" in
      ''|*[!0-9]*) log "could not check Finder Trash; keep it" ;;
      0) log "Finder Trash is already empty" ;;
      *)
        log "empty Finder Trash ($trash_items items)"
        osascript -e 'tell application "Finder" to empty trash' || log "could not empty Finder Trash"
        ;;
    esac
  else
    log "osascript unavailable — keep Finder Trash"
  fi
fi

log "done"
