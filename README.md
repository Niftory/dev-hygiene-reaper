# Dev Hygiene Reaper

Cautious macOS `launchd` jobs for developer-machine cleanup. A fast lane runs
the memory checks every minute. A slow lane runs every five minutes and does
disk and Docker cleanup only when each check is due. A timeout bounds every
step, so a slow cleanup cannot block the memory checks.

The included reapers handle:

- idle dev-server trees (Next, Vite, tsx, Inngest, ...) that are unattended,
  over a day old, in a deleted worktree, or holding memory under swap pressure;
- idle or runaway TypeScript language servers left by agent sessions;
- a total memory cap for the personal Google Chrome;
- orphaned headless Chrome and runaway `agent-browser` sessions under resource pressure;
- a runaway Next.js process tree (one far above normal dev-server size);
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

1. Clone this repository.
2. Put machine settings in `~/.dev-hygiene/config.env`. At least set
   `DEV_HYGIENE_REPOS` to a space-separated list of the primary Git checkouts
   that it may clean.
3. Install both lanes:

   ```bash
   DEV_HYGIENE_LABEL_PREFIX=com.example.dev-hygiene-reaper scripts/install.sh
   ```

The installer copies `scripts/` to `~/.dev-hygiene/current`, so switching
branches in the clone never changes what runs. Run it again after pulling. It
writes and loads two LaunchAgents: `<prefix>.fast` (every 60 seconds, log
`~/.dev-hygiene/reaper-fast.log`) and `<prefix>` (every 5 minutes, log
`~/.dev-hygiene/reaper.log`). It does not reload a lane in the middle of a run
unless you pass `--force`.

Use this to check a job:

```bash
launchctl print "gui/$(id -u)/com.example.dev-hygiene-reaper.fast"
```

Unload it with:

```bash
launchctl bootout "gui/$(id -u)/com.example.dev-hygiene-reaper.fast"
```

`launchd/com.example.dev-hygiene-reaper.plist` remains as a single-job
example. Without `--lane`, `reaper.sh` runs both lanes in order.

## Cadence

| Lane | Check | Cadence |
| --- | --- | --- |
| fast | Stale dev servers, idle language servers, Chrome tab cap | Every minute |
| fast | Headless Chrome, Next.js, ChatGPT helpers, Vitest | Every 5 minutes |
| slow | `agent-browser` daemons | Hourly |
| slow | Local dev services | Hourly |
| slow | Workspace cache and worktree cleanup | Every 6 hours |
| slow | Agent temporary artifact cleanup | Daily |
| slow | Docker cleanup | Daily |
| slow | Node and package tooling cleanup | Weekly |

## Configure

All thresholds use environment variables. The defaults are documented near the
top of each script. `reaper.sh` also reads `~/.dev-hygiene/config.env` on each
run, so a change takes effect without reloading `launchd`. Useful settings
include:

- `DEV_HYGIENE_OVERRIDE_DIR`: a directory searched first for each sub-script,
  for locally tuned copies of individual reapers.
- `DEV_REAP_UNATTENDED_AGE_SEC`, `DEV_REAP_UNATTENDED_IDLE_SEC`,
  `DEV_REAP_MAX_AGE_SEC`, `DEV_REAP_PRESSURE_SWAP_MB`, and
  `DEV_REAP_PROTECT` (path prefixes that are never reaped).
- `LSP_REAP_IDLE_SEC`, `LSP_REAP_MIN_MB`, `LSP_REAP_RUNAWAY_MB`, and
  `LSP_REAP_EDITORS`.
- `CHROME_TAB_CAP_MB`: the personal Chrome memory cap. Defaults to 24 GiB.
- `DEV_HYGIENE_FAST_STEP_TIMEOUT_SEC` and `DEV_HYGIENE_SLOW_STEP_TIMEOUT_SEC`.
- `DEV_HYGIENE_REPOS`: space-separated primary Git checkout paths.
- `DEV_HYGIENE_STALE_DAYS`: age before a clean linked worktree is removed.
- `DEV_HYGIENE_STRIP_HOURS`: idle age before linked-worktree dependencies are removed.
- `AGENT_ARTIFACT_MAX_AGE_DAYS`: age before known agent temporary directories are removed.
- `DEV_HYGIENE_PROJECTS_ROOT`: parent directory used to verify Docker Compose projects.
- `NEXT_REAP_TREE_MAX_MB` (default 6 GiB footprint) and `NEXT_REAP_MIN_AGE_SEC`.
- `CHROME_REAP_CPU_PERCENT`, `CHROME_REAP_RAM_PERCENT`,
  `CHROME_REAP_PROFILE_RSS_MB`, and `CHROME_REAP_MIN_AGE_SEC`.
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

The idle agent-browser check matches the daemon executable basename. It does
not mistake a worktree under `.claude/` for the Claude application.

The Docker reaper deletes dangling anonymous volumes. It can also delete a
dangling named volume when its known agent project directory no longer exists.
It preserves base project volumes and all volumes for existing project paths.
It also prunes stopped containers, unused images, and unreferenced build cache.

## Test safely

`scripts/memory-audit.sh` is read-only. It shows memory by app and what the
memory-lane reapers would close now.

Run individual process reapers with `--dry-run`:

```bash
bash scripts/reap-stale-dev-servers.sh --dry-run
bash scripts/reap-idle-lsp.sh --dry-run
bash scripts/reap-chrome-tab-cap.sh --dry-run
bash scripts/reap-next-jobs.sh --dry-run
bash scripts/reap-runaway-vitest.sh --dry-run
bash scripts/reap-orphaned-chatgpt-helpers.sh --dry-run
bash scripts/reap-runaway-chrome.sh --dry-run
bash scripts/reap-idle-agent-browser.sh --dry-run
bash scripts/reap-dev-services.sh --dry-run
```

The service reaper matches explicit local dev commands. It never matches a
bare process name, walks upward to a shell, or targets a remote service.

The stale dev-server reaper groups a dev command with the package-runner
wrappers above it and every child below it. It stops at any shell, terminal,
agent, or launchd. A worktree is attended while a shell, agent, or editor has
its working directory inside it. Memory is the physical footprint that
Activity Monitor shows, not RSS. A swapped-out server has a small RSS, so
ranking by RSS would spare the stale servers that fill swap. Idle means the
whole tree used under 3% CPU since the previous run. A tree seen for the
first time is not idle yet, so the idle rules act only after the idle period
passes. Pass `--bootstrap-idle` to a manual run to treat unseen trees as idle
since they started.

The Chrome reaper checks launcher and agent-browser temp profiles every five
minutes. It closes old orphaned headless Chrome trees. It also closes an
agent-browser profile when one renderer reaches 80% CPU, or when system RAM
use reaches 80% and that profile uses at least 512 MiB. It never targets a
personal Chrome profile or a live Lighthouse run. Use `--dry-run` to inspect
targets without signaling them.

The storage and Docker reapers perform cleanup when run. Inspect them and use
a disposable machine or test checkout first.
