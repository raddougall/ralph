# ClickUp Story Sync

This folder contains shared helper scripts to keep ClickUp story tasks and local `prd.json` in sync.

Recommended usage: run the project-local wrappers created by `scripts/install-project-launcher.sh` (for example `./scripts/clickup/sync_clickup_to_prd.sh` and `./scripts/clickup/sync_prd_to_clickup.sh` from your project root).

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
