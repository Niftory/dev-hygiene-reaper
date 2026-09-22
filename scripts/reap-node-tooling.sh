#!/usr/bin/env bash
# Remove regenerable package-manager data and superseded Node patch versions.
set -uo pipefail

NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
PNPM_STORE_ROOT="${PNPM_STORE_ROOT:-$HOME/Library/pnpm/store}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

clear_cache() {
  local cache="$1"
  [ -d "$cache" ] || return
  log "clear cache $(human "$cache"): $cache"
  chmod -R u+w "$cache" 2>/dev/null || true
  find "$cache" -mindepth 1 -depth -delete 2>/dev/null || \
    log "could not fully clear cache: $cache"
}

newest_node_bin="$(
  find "$NVM_DIR/versions/node" -mindepth 2 -maxdepth 2 -type d -name bin -print \
    2>/dev/null | sort -V | tail -1
)"
[ -n "$newest_node_bin" ] && PATH="$newest_node_bin:$PATH"

current_store="$(pnpm store path 2>/dev/null || true)"
if [ -n "$current_store" ] && [ -d "$PNPM_STORE_ROOT" ]; then
  for store in "$PNPM_STORE_ROOT"/v*; do
    [ -d "$store" ] || continue
    [ "$store" = "$current_store" ] && continue
    log "remove legacy pnpm store $(human "$store"): $store"
    find "$store" -depth -delete 2>/dev/null || log "could not remove: $store"
  done
fi

if command -v pnpm >/dev/null 2>&1; then
  log "prune current pnpm store: ${current_store:-unknown}"
  pnpm store prune 2>&1 | sed 's/^/  /'
fi

if command -v npm >/dev/null 2>&1; then
  log "clean npm cache"
  npm cache clean --force 2>&1 | sed 's/^/  /'
fi

for cache in \
  "$HOME/.cache/node" \
  "$HOME/.cache/prisma" \
  "$HOME/.bun/install/cache" \
  "$HOME/Library/Caches/node-gyp" \
  "$HOME/Library/Caches/pip" \
  "$HOME/Library/Caches/.wrangler" \
  "$HOME/Library/Caches/ms-playwright-go" \
  "$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation" \
  "$HOME/Library/Caches/Codex/Default/Partitions/codex-browser-app/Cache" \
  "$HOME/Library/Caches/Codex/Default/Partitions/codex-browser-app/Code Cache"; do
  clear_cache "$cache"
done

if [ -f "$NVM_DIR/nvm.sh" ]; then
  # shellcheck source=/dev/null
  source "$NVM_DIR/nvm.sh"
  nvm cache clear >/dev/null 2>&1 || true
  for installed in "$NVM_DIR"/versions/node/v*; do
    [ -d "$installed" ] || continue
    version="${installed##*/v}"
    major="${version%%.*}"
    newest="$(
      find "$NVM_DIR/versions/node" -mindepth 1 -maxdepth 1 -type d \
        -name "v$major.*" -print 2>/dev/null | sort -V | tail -1
    )"
    [ -n "$newest" ] || continue
    [ "$installed" = "$newest" ] && continue
    log "uninstall superseded Node patch: v$version"
    nvm uninstall "$version" 2>&1 | sed 's/^/  /'
  done
fi

log "done"
