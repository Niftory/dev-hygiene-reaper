# Dev Hygiene Reaper

A cautious macOS `launchd` job for developer-machine cleanup. It starts every
five minutes. It runs fast memory checks each time and slower checks only when
they are due.

The included reapers handle:

- oversized or swap-stressed Next.js process trees;
- abandoned ChatGPT helper processes;
- runaway Vitest runs;
- idle `agent-browser` daemons;
- rebuildable workspace caches and stale clean Git worktrees; and
- unused Docker state.

This project is macOS-specific. It uses `launchd`, `sysctl`, and BSD `stat`.

## Install

Read each script before you use it. The scripts can terminate processes and
delete rebuildable data.

1. Clone this repository to a stable path.
2. Copy `launchd/com.example.dev-hygiene-reaper.plist` to
   `~/Library/LaunchAgents/com.example.dev-hygiene-reaper.plist`.
3. Replace `/ABSOLUTE/PATH/TO/dev-hygiene-reaper` with the clone path.
4. Set `DEV_HYGIENE_REPOS` in the plist environment to a space-separated list
   of the primary Git checkouts that it may clean.
5. Load the job:

   ```bash
   launchctl bootstrap "gui/$(id -u)" \
     "$HOME/Library/LaunchAgents/com.example.dev-hygiene-reaper.plist"
   ```

Use this to check the job:

```bash
launchctl print "gui/$(id -u)/com.example.dev-hygiene-reaper"
```

Unload it with:

```bash
launchctl bootout "gui/$(id -u)/com.example.dev-hygiene-reaper"
```

## Cadence

| Check | Cadence |
| --- | --- |
| Next.js, ChatGPT helpers, Vitest | Every 5 minutes |
| `agent-browser` daemons | Hourly |
| Workspace cache and worktree cleanup | Every 6 hours |
| Docker cleanup | Daily |

## Configure

All thresholds use environment variables. The defaults are documented near the
top of each script. Useful settings include:

- `DEV_HYGIENE_REPOS`: space-separated primary Git checkout paths.
- `DEV_HYGIENE_STALE_DAYS`: age before a clean linked worktree is removed.
- `NEXT_REAP_SWAP_MAX_MB` and `NEXT_REAP_TREE_RSS_MAX_MB`.
- `VITEST_REAP_AGE_MIN_SEC` and `VITEST_REAP_RSS_MAX_MB`.

The Docker reaper deletes only dangling anonymous volumes. It also prunes
stopped containers, unused images, and unreferenced build cache.

## Test safely

Run individual process reapers with `--dry-run`:

```bash
bash scripts/reap-next-jobs.sh --dry-run
bash scripts/reap-runaway-vitest.sh --dry-run
bash scripts/reap-orphaned-chatgpt-helpers.sh --dry-run
bash scripts/reap-idle-agent-browser.sh --dry-run
```

The storage and Docker reapers perform cleanup when run. Inspect them and use
a disposable machine or test checkout first.
