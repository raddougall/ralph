#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-$(pwd)}"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
TARGET_JARVIS_DIR="$TARGET_DIR/scripts/jarvis"
TARGET_RALPH_DIR="$TARGET_DIR/scripts/ralph"
TARGET_CLICKUP_DIR="$TARGET_DIR/scripts/clickup"

mkdir -p "$TARGET_JARVIS_DIR" "$TARGET_RALPH_DIR" "$TARGET_CLICKUP_DIR"

cat > "$TARGET_JARVIS_DIR/jarvis.sh" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_ENV_FILE="$PROJECT_ROOT/scripts/jarvis/.env.jarvis.local"
if [ -f "$LOCAL_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$LOCAL_ENV_FILE"
  set +a
fi

JARVIS_HOME="${JARVIS_HOME:-${RALPH_HOME:-}}"
if [ -z "$JARVIS_HOME" ]; then
  if [ -d "$HOME/CodeDev/Jarvis" ]; then
    JARVIS_HOME="$HOME/CodeDev/Jarvis"
  else
    JARVIS_HOME="$HOME/CodeDev/Ralph"
  fi
fi
MASTER_JARVIS="$JARVIS_HOME/jarvis.sh"

if [ ! -x "$MASTER_JARVIS" ]; then
  echo "Master Jarvis launcher not found or not executable: $MASTER_JARVIS" >&2
  echo "Set JARVIS_HOME (or legacy RALPH_HOME) to your Jarvis repo path." >&2
  exit 1
fi

export JARVIS_PROJECT_DIR="$PROJECT_ROOT"
# Backward-compat for scripts that still read RALPH_PROJECT_DIR.
export RALPH_PROJECT_DIR="${RALPH_PROJECT_DIR:-$JARVIS_PROJECT_DIR}"
exec "$MASTER_JARVIS" "$@"
LAUNCHER
chmod +x "$TARGET_JARVIS_DIR/jarvis.sh"

cat > "$TARGET_RALPH_DIR/ralph.sh" <<'RALPH_SHIM'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/../jarvis/jarvis.sh" "$@"
RALPH_SHIM
chmod +x "$TARGET_RALPH_DIR/ralph.sh"

cat > "$TARGET_JARVIS_DIR/README.md" <<'DOC'
# Jarvis Launcher (Project-Local)

This project uses the shared master Jarvis runtime.

- Primary launcher: `scripts/jarvis/jarvis.sh`
- Legacy compatibility launcher: `scripts/ralph/ralph.sh`
- Default shared runtime path: `$HOME/CodeDev/Jarvis` (fallback `$HOME/CodeDev/Ralph`)
- Override path with: `JARVIS_HOME=/path/to/Jarvis` (legacy `RALPH_HOME` still supported)

The launcher pins execution to this repo by exporting:

- `JARVIS_PROJECT_DIR=<this repo root>`

That means all working files (`prd.json`, `progress.txt`, `archive/`, logs, branch tracking) stay inside this project directory.

## Local secrets (recommended)

Create `scripts/jarvis/.env.jarvis.local` for local-only secrets and runtime flags (for example `OPENAI_API_KEY`).
The launcher auto-loads this file before running Jarvis.

Example:

```bash
cp scripts/jarvis/.env.jarvis.example scripts/jarvis/.env.jarvis.local
```

## Usage

```bash
JARVIS_AGENT=codex ./scripts/jarvis/jarvis.sh
```

Legacy equivalent (still works):

```bash
RALPH_AGENT=codex ./scripts/ralph/ralph.sh
```

## Optional per-project prompt override

If you need project-specific prompt customization without forking the full runtime,
create `.jarvis/prompt.md` in this project (legacy `.ralph/prompt.md` also supported).
DOC

if [ ! -f "$TARGET_JARVIS_DIR/.env.jarvis.example" ]; then
  cat > "$TARGET_JARVIS_DIR/.env.jarvis.example" <<'JARVIS_ENV'
# Local-only Jarvis/Codex secrets (do not commit actual values)
OPENAI_API_KEY=

# Optional runtime defaults
# JARVIS_AGENT=codex
# JARVIS_CODEX_ENABLE_NETWORK=1
# JARVIS_CLICKUP_SYNC_ON_START=1
# JARVIS_CLICKUP_SYNC_STRICT=0
JARVIS_ENV
fi

cat > "$TARGET_CLICKUP_DIR/get_oauth_token.sh" <<'CLICKUP_OAUTH'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JARVIS_HOME="${JARVIS_HOME:-${RALPH_HOME:-}}"
if [ -z "$JARVIS_HOME" ]; then
  if [ -d "$HOME/CodeDev/Jarvis" ]; then
    JARVIS_HOME="$HOME/CodeDev/Jarvis"
  else
    JARVIS_HOME="$HOME/CodeDev/Ralph"
  fi
fi
MASTER_SCRIPT="$JARVIS_HOME/scripts/clickup/get_oauth_token.sh"

if [ ! -x "$MASTER_SCRIPT" ]; then
  echo "Master ClickUp script not found or not executable: $MASTER_SCRIPT" >&2
  echo "Set JARVIS_HOME (or legacy RALPH_HOME) to your Jarvis repo path." >&2
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
JARVIS_HOME="${JARVIS_HOME:-${RALPH_HOME:-}}"
if [ -z "$JARVIS_HOME" ]; then
  if [ -d "$HOME/CodeDev/Jarvis" ]; then
    JARVIS_HOME="$HOME/CodeDev/Jarvis"
  else
    JARVIS_HOME="$HOME/CodeDev/Ralph"
  fi
fi
MASTER_SCRIPT="$JARVIS_HOME/scripts/clickup/sync_prd_to_clickup.sh"

if [ ! -x "$MASTER_SCRIPT" ]; then
  echo "Master ClickUp script not found or not executable: $MASTER_SCRIPT" >&2
  echo "Set JARVIS_HOME (or legacy RALPH_HOME) to your Jarvis repo path." >&2
  exit 1
fi

cd "$PROJECT_ROOT"
exec "$MASTER_SCRIPT" "$@"
CLICKUP_SYNC
chmod +x "$TARGET_CLICKUP_DIR/sync_prd_to_clickup.sh"

cat > "$TARGET_CLICKUP_DIR/sync_clickup_to_prd.sh" <<'CLICKUP_PULL'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JARVIS_HOME="${JARVIS_HOME:-${RALPH_HOME:-}}"
if [ -z "$JARVIS_HOME" ]; then
  if [ -d "$HOME/CodeDev/Jarvis" ]; then
    JARVIS_HOME="$HOME/CodeDev/Jarvis"
  else
    JARVIS_HOME="$HOME/CodeDev/Ralph"
  fi
fi
MASTER_SCRIPT="$JARVIS_HOME/scripts/clickup/sync_clickup_to_prd.sh"

if [ ! -x "$MASTER_SCRIPT" ]; then
  echo "Master ClickUp script not found or not executable: $MASTER_SCRIPT" >&2
  echo "Set JARVIS_HOME (or legacy RALPH_HOME) to your Jarvis repo path." >&2
  exit 1
fi

cd "$PROJECT_ROOT"
exec "$MASTER_SCRIPT" "$@"
CLICKUP_PULL
chmod +x "$TARGET_CLICKUP_DIR/sync_clickup_to_prd.sh"

cat > "$TARGET_CLICKUP_DIR/README.md" <<'CLICKUP_DOC'
# ClickUp Scripts (Project-Local Wrappers)

This project uses shared ClickUp scripts from Jarvis.

- `scripts/clickup/get_oauth_token.sh`
- `scripts/clickup/sync_clickup_to_prd.sh`
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

## Task Update Conventions (Jarvis Runs)

For each completed story, add a task activity comment that includes:

- what changed
- test commands run and pass/fail outcomes
- repo-relative paths of automated test files added/updated
- manual smoke-test outcome (or explicitly `none`)
- final outcome / ready-for-testing note

For traceability:

- attach commit links to the story task
- link related tasks (for example bug task linked to originating story task)
- use ClickUp task type `bug` for bug reports/fixes, not generic story/task type
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
CLICKUP_PRUNE_MISSING=0
CLICKUP_SYNC_APPEND_PROGRESS=1
CLICKUP_GITHUB_REPO_URL=
CLICKUP_ATTACH_COMMIT_LINKS=1
CLICKUP_POST_TESTING_COMMENT=1
CLICKUP_MOVE_TO_TESTING=1
CLICKUP_MOVE_TO_IN_PROGRESS=1
CLICKUP_DRY_RUN=0
CLICKUP_ENV
fi

ensure_gitignore_entry() {
  local entry="$1"
  local file="$TARGET_DIR/.gitignore"
  if [ ! -f "$file" ]; then
    touch "$file"
  fi
  if ! grep -Fxq "$entry" "$file"; then
    printf '\n%s\n' "$entry" >> "$file"
  fi
}

ensure_gitignore_entry "scripts/jarvis/.env.jarvis.local"
ensure_gitignore_entry "scripts/clickup/.env.clickup"

echo "Installed Jarvis launcher at: $TARGET_JARVIS_DIR"
echo "Installed Ralph compatibility launcher at: $TARGET_RALPH_DIR"
echo "Installed ClickUp wrappers at: $TARGET_CLICKUP_DIR"
