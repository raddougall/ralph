# ClickUp Story Sync

This folder contains shared helper scripts to keep ClickUp story tasks and local `prd.json` in sync.

Recommended usage: run the project-local wrappers created by `scripts/install-project-launcher.sh` (for example `./scripts/clickup/sync_clickup_to_prd.sh`, `./scripts/clickup/sync_prd_to_clickup.sh`, and `./scripts/clickup/sync_jarvis_directives_to_clickup.sh` from your project root).

## 1) Get an OAuth access token (if you are using OAuth app credentials)

You can keep secrets in a local file (auto-created by `scripts/install-project-launcher.sh` when missing):

```bash
cp scripts/clickup/.env.clickup.example scripts/clickup/.env.clickup
```

Then load it before running scripts:

```bash
set -a
source scripts/clickup/.env.clickup
set +a
```

1. Build an authorization URL in your browser:

```
https://app.clickup.com/api?client_id=YOUR_CLIENT_ID&redirect_uri=YOUR_REDIRECT_URI
```

2. Approve access, then copy the `code` query parameter from the redirect URL.
3. Exchange code for token:

```bash
CLICKUP_CLIENT_ID=... \
CLICKUP_CLIENT_SECRET=... \
CLICKUP_REDIRECT_URI=http://localhost:3333/clickup/callback \
CLICKUP_AUTH_CODE=... \
./scripts/clickup/get_oauth_token.sh
```

The script prints an access token. Use it as `CLICKUP_TOKEN`.

## 2) Pull ClickUp stories into local `prd.json`

```bash
CLICKUP_TOKEN=... \
CLICKUP_LIST_URL="https://app.clickup.com/123/v/li/456" \
./scripts/clickup/sync_clickup_to_prd.sh
```

Or:

```bash
CLICKUP_TOKEN=... \
CLICKUP_LIST_ID=456 \
./scripts/clickup/sync_clickup_to_prd.sh
```

The pull sync script:

- reads tasks with names like `[US-xxx] ...`
- updates or creates matching stories in local `prd.json`
- stores ClickUp `orderindex` as `clickupOrder` for optional manual-order execution mode
- maps ClickUp done/closed statuses to `passes=true`
- can optionally prune local-only stories with `CLICKUP_PRUNE_MISSING=1`
- can append a sync note to `progress.txt` (`CLICKUP_SYNC_APPEND_PROGRESS=1`)

## 3) Push local `prd.json` stories into ClickUp

```bash
CLICKUP_TOKEN=... \
CLICKUP_LIST_URL="https://app.clickup.com/123/v/li/456" \
./scripts/clickup/sync_prd_to_clickup.sh
```

Or:

```bash
CLICKUP_TOKEN=... \
CLICKUP_LIST_ID=456 \
./scripts/clickup/sync_prd_to_clickup.sh
```

The sync script:

- Reads stories from `prd.json`
- Maps story status to your list statuses automatically:
  - `passes=true` -> first done/closed status in the list
  - `passes=false` -> `to do` by default (or first non-`backlog` open/custom status if `to do` is missing)
- Creates missing tasks
- Updates existing tasks matching the `[US-xxx]` prefix

Use `CLICKUP_STATUS_TODO` if your ready-to-work status has a different label.
For branch-based workflows, keep `JARVIS_CLICKUP_AUTO_DEPLOY_ON_MAIN=0` so `passes=true` maps to `done` on main and `testing` on non-main by default. To keep main in verification, set `JARVIS_CLICKUP_MAIN_COMPLETION_STATUS=testing`. Enable main-only deploy transitions with `JARVIS_CLICKUP_AUTO_DEPLOY_ON_MAIN=1` when desired.

Example:

```bash
CLICKUP_TOKEN=... \
CLICKUP_LIST_ID=456 \
CLICKUP_STATUS_TODO="to do" \
./scripts/clickup/sync_prd_to_clickup.sh
```

Recommended list convention:

- `backlog` = future ideas only
- `to do` = planned/approved tasks ready for execution

## Task Update Conventions (Jarvis Runs)

For each story, post task activity comments during execution (`start`, `progress`, `testing`), prefixed with a `Jarvis/Codex` label. Jarvis/Codex should post these directly (do not ask the user to copy/paste updates).

Completion comment must include:

- what changed
- test commands run and pass/fail outcomes
- repo-relative paths of automated test files added/updated
- manual smoke-test outcome (or explicitly `none`)
- final outcome / ready-for-testing note

For traceability:

- attach commit links to the story task
- link related tasks (for example bug task linked to originating story task)
- use ClickUp task type `bug` for bug reports/fixes, not generic story/task type
- keep final ClickUp completion note aligned with the same implementation/test summary shared in terminal output

## 4) Sync Jarvis directives overview into ClickUp

Use this to maintain a human-readable directives reference doc in ClickUp.

```bash
CLICKUP_TOKEN=... \
CLICKUP_LIST_ID=456 \
./scripts/clickup/sync_jarvis_directives_to_clickup.sh
```

Optional variables:

- `CLICKUP_DIRECTIVES_DOC_URL` (recommended; parse workspace/doc id automatically)
- or `CLICKUP_WORKSPACE_ID` + `CLICKUP_DIRECTIVES_DOC_ID`
- `CLICKUP_DIRECTIVES_PAGE_ID` (optional; auto-selects first page if omitted)
- `CLICKUP_DIRECTIVES_SOURCE_FILE` (default: `./docs/jarvis-directives-overview.md`, fallback to Jarvis master docs file)

Per-project setup note:

- Put the target doc URL in that project’s `scripts/clickup/.env.clickup`.
- Different projects can point to different docs by setting different `CLICKUP_DIRECTIVES_DOC_URL` values.

## Dry-run

```bash
CLICKUP_TOKEN=... \
CLICKUP_LIST_ID=456 \
DRY_RUN=1 \
./scripts/clickup/sync_prd_to_clickup.sh
```

```bash
CLICKUP_TOKEN=... \
CLICKUP_LIST_ID=456 \
DRY_RUN=1 \
./scripts/clickup/sync_clickup_to_prd.sh
```

## 5) Calibrate Codex effort fields every 3 stories

Use `codex_allowance_calibrate.sh` to convert story effort minutes into approximate `%` values in your ClickUp custom fields (`Codex 5-hour`, `Codex Weekly`, `Codex Window`) using real `%` consumption samples from your own account.

This avoids hard-coding limits and recalibrates from observed usage.

### Files

- Calibration samples CSV (default): `./.codex/codex_allowance_samples.csv`
- Story estimate CSV (default): `./.codex/codex_story_estimates.csv`

### Record a completed story sample

```bash
set -a
source scripts/clickup/.env.clickup
set +a

./scripts/clickup/codex_allowance_calibrate.sh record \
  --story US-063 \
  --minutes 45 \
  --five-before 82 \
  --five-after 78 \
  --weekly-before 66 \
  --weekly-after 65
```

Run this after each completed story. The script computes capacities from the latest 3 samples by default (`CALIBRATION_SAMPLE_SIZE=3`).

Auto-run mode (recommended):

```bash
CODEX_AUTO_APPLY_ON_RECORD=1 CODEX_AUTO_APPLY_EVERY=3 ./scripts/clickup/codex_allowance_calibrate.sh record   --story US-063   --minutes 45   --five-before 82   --five-after 78   --weekly-before 66   --weekly-after 65
```

When enabled, `record` triggers `apply` automatically whenever sample count reaches a multiple of `CODEX_AUTO_APPLY_EVERY`.

`apply` writes:
- `Codex 5-hour`: approximate percent of your 5-hour allowance
- `Codex Weekly`: approximate percent of your weekly allowance
- `Codex Window`: scheduling bucket
- Task description summary block with both P80 minutes and calibrated percentages

### Recalculate capacities manually

```bash
./scripts/clickup/codex_allowance_calibrate.sh recalc
```

### Apply calibrated values to ClickUp fields

```bash
set -a
source scripts/clickup/.env.clickup
set +a

./scripts/clickup/codex_allowance_calibrate.sh apply
```

Optional:

- `DRY_RUN=1` to preview updates only
- `CODEX_WINDOW_NOW_THRESHOLD_PCT` (default `35`)
- `CODEX_WINDOW_WEEKLY_THRESHOLD_PCT` (default `35`)
- `CALIBRATION_SAMPLE_SIZE` (default `3`)

Expected custom field names (override via env if needed):

- `Codex 5-hour` (number)
- `Codex Weekly` (number)
- `Codex Window` (drop down: `5h-Now`, `Weekly`, `Later`)
