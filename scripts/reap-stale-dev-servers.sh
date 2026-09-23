#!/usr/bin/env bash
#
# reap-stale-dev-servers.sh — close local dev-server trees nobody is using.
#
# Agents start dev servers in worktrees, background them, and move on. Those
# servers outlive the task by days and page gigabytes into swap. This reaper
# finds each dev-server tree and closes it when one of these rules holds:
#
#   gone        its working directory no longer exists (worktree removed);
#   unattended  no agent, shell, or editor has a working directory inside the
#               same worktree, the tree is at least DEV_REAP_UNATTENDED_AGE_SEC
#               old, and it has been idle for DEV_REAP_UNATTENDED_IDLE_SEC;
#   max-age     it is older than DEV_REAP_MAX_AGE_SEC and has been idle for
#               DEV_REAP_MAX_AGE_IDLE_SEC, whoever owns it;
#   pressure    swap use is at least DEV_REAP_PRESSURE_SWAP_MB. Then the
#               largest idle tree closes, one per run, unattended trees first.
#
# A tree is a dev command (Next, Vite, tsx, nodemon, Storybook, Inngest, ...)
# plus the package-runner wrappers above it (pnpm, npm, concurrently,
# dotenv, sh -c) and everything below it. The walk up stops at any shell,
# terminal, agent, or launchd, so those are never signalled. Memory is the
# physical footprint, not RSS; see lib/proc.sh.
#
# Idle means the whole tree used less than IDLE_CPU_PERCENT of wall time
# since the previous run. A tree seen for the first time starts idle "now",
# so nothing reaps on the first run except the gone rule. For a one-shot
# manual cleanup, pass --bootstrap-idle to treat unseen trees as idle since
# they started.
#
# Usage:
#   reap-stale-dev-servers.sh [--dry-run] [--bootstrap-idle]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/proc.sh
. "$SCRIPT_DIR/lib/proc.sh"

MIN_AGE_SEC="${DEV_REAP_MIN_AGE_SEC:-600}"
UNATTENDED_AGE_SEC="${DEV_REAP_UNATTENDED_AGE_SEC:-3600}"
UNATTENDED_IDLE_SEC="${DEV_REAP_UNATTENDED_IDLE_SEC:-1800}"
MAX_AGE_SEC="${DEV_REAP_MAX_AGE_SEC:-86400}"
MAX_AGE_IDLE_SEC="${DEV_REAP_MAX_AGE_IDLE_SEC:-1800}"
PRESSURE_SWAP_MB="${DEV_REAP_PRESSURE_SWAP_MB:-12288}"
PRESSURE_IDLE_SEC="${DEV_REAP_PRESSURE_IDLE_SEC:-600}"
PRESSURE_MIN_MB="${DEV_REAP_PRESSURE_MIN_MB:-256}"
# Space-separated path prefixes whose dev servers are never reaped.
PROTECT="${DEV_REAP_PROTECT:-}"
STATE_DIR="${DEV_HYGIENE_STATE_DIR:-$HOME/.dev-hygiene}"
STATE_FILE="$STATE_DIR/dev-server-reaper-state"

# The dev command itself. Keep these specific: a bare tool name is not enough.
ANCHOR_RE='next dev|next-server|/vite/bin/vite\.js|node_modules/\.bin/vite( |$)|tsx/dist/cli\.mjs|tsx/dist/loader\.mjs|/nodemon( |$)|/nodemon/bin/|storybook dev|inngest(-cli)?(/bin/inngest)? dev|wrangler dev|astro dev|mastra dev|webpack serve|react-scripts start|turbo (run )?dev'
# Package runners and wrappers that belong to the tree above a dev command,
# matched against the first two words of the command line.
LAUNCHER_RE='(^|/)(pnpm|npm|npx|yarn|bun|bunx|corepack|concurrently|dotenv|dotenv-cli|cross-env|turbo|nx|run-p|npm-run-all)([ /.]|$)|^(/bin/)?sh -c'
# Commands that are never a dev tree: shells, terminals, and agents.
NEVER_RE='^(-?/?[^ ]*/)?-?(zsh|bash|fish|login|tmux|screen|claude|codex)( |$)'
# Processes whose working directory marks a worktree as attended.
PRESENCE_RE='(^|/)-?(zsh|bash|fish|tmux|claude|codex|nvim|vim|emacs|Cursor|Code|Zed|zed)( |$)'

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --bootstrap-idle) export BOOTSTRAP_IDLE=1 ;;
  esac
done

mkdir -p "$STATE_DIR"
SNAP="$(mktemp -d "${TMPDIR:-/tmp}/dev-reap.XXXXXX")"
trap 'rm -rf "$SNAP"' EXIT
# Take the clock first: ps reports ages relative to its own start.
now="$(date +%s)"
proc_snapshot "$SNAP"
swap_mb="$(swap_used_mb)"; swap_mb="${swap_mb:-0}"

# Roots: walk up from each dev command while the parent is a wrapper or
# another dev command. Never start from, or climb into, a shell or agent.
/usr/bin/awk -v anchor="$ANCHOR_RE" -v launcher="$LAUNCHER_RE" -v never="$NEVER_RE" -v self="$$" '
  {
    pid = $1; ppid[pid] = $2; c = $0
    for (i = 1; i <= 4; i++) sub(/^[^ ]+ /, "", c)
    cmd[pid] = c; split(c, t, " "); head[pid] = t[1] " " t[2]; order[++n] = pid
  }
  function member(p) { return (cmd[p] ~ anchor || head[p] ~ launcher) && head[p] !~ never }
  END {
    for (i = 1; i <= n; i++) {
      p = order[i]
      if (cmd[p] !~ anchor || head[p] ~ never || p == self) continue
      r = p; hops = 0
      while (hops++ < 32) {
        q = ppid[r]
        if (q <= 1 || !(q in cmd) || !member(q)) break
        r = q
      }
      root[r] = 1
    }
    for (r in root) print r
  }' "$SNAP/ps" > "$SNAP/roots"

# One pass over the snapshot: stats and working directory per root, plus
# every pid inside a dev tree so presence checks can ignore the trees.
: > "$SNAP/members"
: > "$SNAP/state"
tree_table "$SNAP" "$SNAP/members" < "$SNAP/roots" \
  | with_idle "$STATE_FILE" "$SNAP/state" "$now" > "$SNAP/table"

# Working directories of shells, agents, and editors outside the dev trees.
/usr/bin/awk -v presence="$PRESENCE_RE" -v home="$HOME" '
  FILENAME == ARGV[1] { skip[$1] = 1; next }
  FILENAME == ARGV[2] { c = $0; for (i = 1; i <= 4; i++) sub(/^[^ ]+ /, "", c); split(c, t, " ")
                        if (t[1] ~ presence && !($1 in skip)) keep[$1] = 1; next }
  { split($0, f, "\t"); if ((f[1] in keep) && f[2] != "/" && f[2] != home) print f[2] }
' "$SNAP/members" "$SNAP/ps" "$SNAP/cwd" | sort -u > "$SNAP/presence"

attended() {
  local tree="$1" dir
  while IFS= read -r dir; do is_under "$dir" "$tree" && return 0; done < "$SNAP/presence"
  return 1
}

protected() {
  local path="$1" prefix
  for prefix in $PROTECT; do is_under "$path" "$prefix" && return 0; done
  return 1
}

: > "$SNAP/candidates"
: > "$SNAP/reap"
reaped=0
kept=0
while IFS="$US" read -r since root age _cpu mb count dir _parent cmd; do
  [ -n "$root" ] || continue
  idle=$(( now - since ))
  if [ -z "$dir" ]; then
    # Unknown cwd means lsof failed for this pid. Never guess; keep the tree.
    kept=$((kept + 1)); continue
  fi
  tree="$(worktree_of "$dir")"
  owner="unattended"; attended "$tree" && owner="attended"
  desc="root $root [${count} procs, ${mb}MiB, age $((age / 60))m, idle $((idle / 60))m, $owner] ${tree/#$HOME/~} :: ${cmd:0:110}"

  if [ "$age" -lt "$MIN_AGE_SEC" ] || protected "$dir"; then
    [ "$DRY_RUN" -eq 1 ] && log "keep (young or protected) $desc"
    kept=$((kept + 1)); continue
  fi

  reason=""
  if [ ! -d "$dir" ]; then
    reason="gone"
  elif [ "$owner" = unattended ] && [ "$age" -ge "$UNATTENDED_AGE_SEC" ] && [ "$idle" -ge "$UNATTENDED_IDLE_SEC" ]; then
    reason="unattended"
  elif [ "$age" -ge "$MAX_AGE_SEC" ] && [ "$idle" -ge "$MAX_AGE_IDLE_SEC" ]; then
    reason="max-age"
  fi

  if [ -n "$reason" ]; then
    echo "$root|$reason|$desc" >> "$SNAP/reap"
  else
    [ "$DRY_RUN" -eq 1 ] && log "keep $desc"
    kept=$((kept + 1))
    # Pressure candidates: idle, not brand new, and big enough to matter.
    if [ "$idle" -ge "$PRESSURE_IDLE_SEC" ] && [ "$age" -ge $((PRESSURE_IDLE_SEC * 3)) ] && [ "$mb" -ge "$PRESSURE_MIN_MB" ]; then
      rank=0; [ "$owner" = unattended ] && rank=1
      echo "$rank $mb $root|pressure (swap ${swap_mb}MiB >= ${PRESSURE_SWAP_MB}MiB)|$desc" >> "$SNAP/candidates"
    fi
  fi
done < "$SNAP/table"

if [ "$swap_mb" -ge "$PRESSURE_SWAP_MB" ] && [ ! -s "$SNAP/reap" ]; then
  sort -k1,1nr -k2,2nr "$SNAP/candidates" | head -1 | cut -d' ' -f3- >> "$SNAP/reap"
  [ -s "$SNAP/reap" ] && kept=$((kept - 1))
fi

while IFS='|' read -r root reason desc; do
  [ -n "$root" ] || continue
  if [ "$DRY_RUN" -eq 1 ]; then
    log "WOULD REAP ($reason) $desc"
  else
    # shellcheck disable=SC2046
    forced="$(kill_tree $(tree_pids "$SNAP" "$root"))"
    log "REAPED ($reason) $desc${forced:+ — $forced needed KILL}"
  fi
  reaped=$((reaped + 1))
done < "$SNAP/reap"

[ "$DRY_RUN" -eq 1 ] || mv -f "$SNAP/state" "$STATE_FILE"
suffix=""; [ "$DRY_RUN" -eq 1 ] && suffix=" (dry-run)"
log "done: $reaped reaped, $kept kept, swap ${swap_mb}MiB$suffix"
