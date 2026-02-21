#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-$(pwd)}"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
TARGET_RALPH_DIR="$TARGET_DIR/scripts/ralph"
TARGET_CLICKUP_DIR="$TARGET_DIR/scripts/clickup"

mkdir -p "$TARGET_RALPH_DIR" "$TARGET_CLICKUP_DIR"

cat > "$TARGET_RALPH_DIR/ralph.sh" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RALPH_HOME="${RALPH_HOME:-$HOME/CodeDev/Ralph}"
MASTER_RALPH="$RALPH_HOME/ralph.sh"

if [ ! -x "$MASTER_RALPH" ]; then
  echo "Master Ralph launcher not found or not executable: $MASTER_RALPH" >&2
  echo "Set RALPH_HOME to your Ralph repo path (example: $HOME/CodeDev/Ralph)." >&2
  exit 1
fi

export RALPH_PROJECT_DIR="$PROJECT_ROOT"
exec "$MASTER_RALPH" "$@"
LAUNCHER
chmod +x "$TARGET_RALPH_DIR/ralph.sh"

cat > "$TARGET_RALPH_DIR/README.md" <<'DOC'
# Ralph Launcher (Project-Local)

This project uses the shared master Ralph runtime from `~/CodeDev/Ralph`.

- Launcher: `scripts/ralph/ralph.sh`
- Default shared runtime path: `$HOME/CodeDev/Ralph`
- Override path with: `RALPH_HOME=/path/to/Ralph`

The launcher pins Ralph execution to this repo by exporting:

- `RALPH_PROJECT_DIR=<this repo root>`

That means all working files (`prd.json`, `progress.txt`, `archive/`, logs, branch tracking) stay inside this project directory.

## Usage

```bash
RALPH_AGENT=codex ./scripts/ralph/ralph.sh
```

Optional network-enabled Codex runs:

```bash
RALPH_AGENT=codex RALPH_CODEX_ENABLE_NETWORK=1 ./scripts/ralph/ralph.sh
```

## Optional per-project prompt override

If you need project-specific prompt customization without forking the full Ralph runtime,
create `.ralph/prompt.md` in this project.
DOC

cat > "$TARGET_CLICKUP_DIR/get_oauth_token.sh" <<'CLICKUP_OAUTH'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RALPH_HOME="${RALPH_HOME:-$HOME/CodeDev/Ralph}"
MASTER_SCRIPT="$RALPH_HOME/scripts/clickup/get_oauth_token.sh"

if [ ! -x "$MASTER_SCRIPT" ]; then
  echo "Master ClickUp script not found or not executable: $MASTER_SCRIPT" >&2
  echo "Set RALPH_HOME to your Ralph repo path (example: $HOME/CodeDev/Ralph)." >&2
  exit 1
fi

cd "$PROJECT_ROOT"
exec "$MASTER_SCRIPT" "$@"
CLICKUP_OAUTH
chmod +x "$TARGET_CLICKUP_DIR/get_oauth_token.sh"

cat > "$TARGET_CLICKUP_DIR/sync_prd_to_clickup.sh" <<'CLICKUP_SYNC'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RALPH_HOME="${RALPH_HOME:-$HOME/CodeDev/Ralph}"
MASTER_SCRIPT="$RALPH_HOME/scripts/clickup/sync_prd_to_clickup.sh"

if [ ! -x "$MASTER_SCRIPT" ]; then
  echo "Master ClickUp script not found or not executable: $MASTER_SCRIPT" >&2
  echo "Set RALPH_HOME to your Ralph repo path (example: $HOME/CodeDev/Ralph)." >&2
  exit 1
fi

cd "$PROJECT_ROOT"
exec "$MASTER_SCRIPT" "$@"
CLICKUP_SYNC
chmod +x "$TARGET_CLICKUP_DIR/sync_prd_to_clickup.sh"

cat > "$TARGET_CLICKUP_DIR/README.md" <<'CLICKUP_DOC'
# ClickUp Scripts (Project-Local Wrappers)

This project uses shared ClickUp scripts from `~/CodeDev/Ralph/scripts/clickup`.

- `scripts/clickup/get_oauth_token.sh`
- `scripts/clickup/sync_prd_to_clickup.sh`

These local wrappers execute the master scripts while keeping defaults project-local
(for example `PRD_FILE=./prd.json`).

## Local env file

Use a project-local env file:

```bash
cp scripts/clickup/.env.clickup.example scripts/clickup/.env.clickup
```

Then load it before running commands:

```bash
set -a
source scripts/clickup/.env.clickup
set +a
```
CLICKUP_DOC

if [ ! -f "$TARGET_CLICKUP_DIR/.env.clickup.example" ]; then
  cat > "$TARGET_CLICKUP_DIR/.env.clickup.example" <<'CLICKUP_ENV'
CLICKUP_CLIENT_ID=
CLICKUP_CLIENT_SECRET=
CLICKUP_REDIRECT_URI=http://localhost:3333/clickup/callback
CLICKUP_AUTH_CODE=
CLICKUP_TOKEN=
CLICKUP_LIST_URL=
CLICKUP_STATUS_TODO=to do
CLICKUP_STATUS_IN_PROGRESS=in progress
CLICKUP_STATUS_TESTING=testing
CLICKUP_GITHUB_REPO_URL=
CLICKUP_ATTACH_COMMIT_LINKS=1
CLICKUP_POST_TESTING_COMMENT=1
CLICKUP_MOVE_TO_TESTING=1
CLICKUP_MOVE_TO_IN_PROGRESS=1
CLICKUP_DRY_RUN=0
CLICKUP_ENV
fi

echo "Installed launcher at: $TARGET_RALPH_DIR"
echo "Installed ClickUp wrappers at: $TARGET_CLICKUP_DIR"
