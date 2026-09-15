# Dev Hygiene Reaper

A cautious macOS `launchd` job for developer-machine cleanup. It starts every
five minutes. It runs fast memory checks each time and slower checks only when
they are due.

The included reapers handle:

- oversized or swap-stressed Next.js process trees;
- abandoned ChatGPT helper processes;
- runaway Vitest runs;
- idle `agent-browser` daemons;
- stale local Inngest, Hatchet, SST, Vite, and Turbo dev processes;
- rebuildable workspace caches, old dependencies, and stale clean Git worktrees;
- stale temporary directories from local coding agents;
- old pnpm stores, package caches, and superseded Node patch versions; and
- unused Docker state, including orphaned agent-project volumes.

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
| Local dev services | Hourly |
| Workspace cache and worktree cleanup | Every 6 hours |
| Agent temporary artifact cleanup | Daily |
| Docker cleanup | Daily |
| Node and package tooling cleanup | Weekly |

## Configure

All thresholds use environment variables. The defaults are documented near the
top of each script. Useful settings include:

- `DEV_HYGIENE_REPOS`: space-separated primary Git checkout paths.
- `DEV_HYGIENE_STALE_DAYS`: age before a clean linked worktree is removed.
- `DEV_HYGIENE_STRIP_HOURS`: idle age before linked-worktree dependencies are removed.
- `AGENT_ARTIFACT_MAX_AGE_DAYS`: age before known agent temporary directories are removed.
- `DEV_HYGIENE_PROJECTS_ROOT`: parent directory used to verify Docker Compose projects.
- `NEXT_REAP_SWAP_MAX_MB` and `NEXT_REAP_TREE_RSS_MAX_MB`.
- `VITEST_REAP_AGE_MIN_SEC` and `VITEST_REAP_RSS_MAX_MB`.
- `DEV_SERVICE_REAP_SERVICES`: space-separated allowlist. Defaults to
  `inngest hatchet sst vite turbo`.
- `DEV_SERVICE_REAP_AGE_MIN_SEC`, `DEV_SERVICE_REAP_IDLE_CPU_SEC`, and
  `DEV_SERVICE_REAP_IDLE_RUNS`.

Storage cleanup skips paths that appear in a live process command. It removes
only clean stale worktrees. Git branches remain. It does not remove dependencies
from the primary checkout.

Agent cleanup matches a narrow list of temporary directory prefixes. It skips
paths that appear in a live process command. It does not touch Codex or Claude
task history, personal files, or browser profiles.

The Docker reaper deletes dangling anonymous volumes. It can also delete a
dangling named volume when its known agent project directory no longer exists.
It preserves base project volumes and all volumes for existing project paths.
It also prunes stopped containers, unused images, and unreferenced build cache.

## Test safely

Run individual process reapers with `--dry-run`:

```bash
bash scripts/reap-next-jobs.sh --dry-run
bash scripts/reap-runaway-vitest.sh --dry-run
bash scripts/reap-orphaned-chatgpt-helpers.sh --dry-run
bash scripts/reap-idle-agent-browser.sh --dry-run
bash scripts/reap-dev-services.sh --dry-run
```

The service reaper matches explicit local dev commands. It never matches a
bare process name, walks upward to a shell, or targets a remote service.

The storage and Docker reapers perform cleanup when run. Inspect them and use
a disposable machine or test checkout first.
