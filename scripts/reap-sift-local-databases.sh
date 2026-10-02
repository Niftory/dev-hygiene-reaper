#!/usr/bin/env bash
# Drop idle, old worktree databases from the owned local Sift Timescale server.
set -uo pipefail

AGE_DAYS="${SIFT_LOCAL_DB_REAP_DAYS:-}"
SIFT_ROOT="${SIFT_LOCAL_DB_REAP_ROOT:-$HOME/Projects/sift}"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

case "$AGE_DAYS" in
  '') log "SIFT_LOCAL_DB_REAP_DAYS is unset — skip"; exit 0 ;;
  *[!0-9]*|0) log "SIFT_LOCAL_DB_REAP_DAYS must be a positive integer — skip"; exit 0 ;;
esac

container="$(docker ps -q --filter 'label=com.docker.compose.project=timescale-db' | head -1)"
[ -n "$container" ] || { log "local Sift Timescale container is not running — skip"; exit 0; }
working_dir="$(docker inspect "$container" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)"
[ "$working_dir" = "$SIFT_ROOT/packages/data/timescale-db" ] || {
  log "container is not the verified local Sift database — skip"
  exit 0
}
data_dir="$(docker exec "$container" psql -U postgres -d postgres -Atc 'SHOW data_directory;' 2>/dev/null || true)"
[ -n "$data_dir" ] || { log "could not resolve local database data directory — skip"; exit 0; }

removed=0
while IFS='|' read -r database oid; do
  case "$database" in sift_[A-Za-z0-9_]*) ;; *) continue ;; esac
  docker exec "$container" sh -lc "test -z \"\$(find '$data_dir/base/$oid' -type f -mtime '-$AGE_DAYS' -print -quit 2>/dev/null)\"" || continue
  active="$(docker exec "$container" psql -U postgres -d postgres -Atc "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname='$database' AND pid<>pg_backend_pid);" 2>/dev/null)"
  [ "$active" = f ] || continue
  if docker exec "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE \"$database\";" >/dev/null; then
    log "drop inactive local Sift database: $database"
    removed=$((removed + 1))
  fi
done < <(docker exec "$container" psql -U postgres -d postgres -At -F '|' -c \
  "SELECT d.datname,d.oid FROM pg_database d WHERE d.datname LIKE 'sift_%' AND NOT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.datname=d.datname AND a.pid<>pg_backend_pid());")

log "done: removed $removed local Sift databases idle for $AGE_DAYS day(s)"
