#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-$(pwd)}"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
TARGET_RALPH_DIR="$TARGET_DIR/scripts/ralph"

mkdir -p "$TARGET_RALPH_DIR"

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

echo "Installed launcher at: $TARGET_RALPH_DIR"
