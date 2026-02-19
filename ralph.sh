#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [max_iterations]

set -e

MAX_ITERATIONS=${1:-10}
AGENT=${RALPH_AGENT:-amp}
AMP_FLAGS=${RALPH_AMP_FLAGS:---dangerously-allow-all}
CODEX_FLAGS=${RALPH_CODEX_FLAGS:---full-auto --color never}
CODEX_BIN=${RALPH_CODEX_BIN:-codex}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
LOG_FILE="$SCRIPT_DIR/ralph.log"

# Guardrail: block host-level package manager mutations unless explicitly allowed.
if [ -d "$SCRIPT_DIR/guard-bin" ]; then
  export PATH="$SCRIPT_DIR/guard-bin:$PATH"
fi

# This must be explicitly set to 1 only after user approval for host-level changes.
export RALPH_ALLOW_SYSTEM_CHANGES=${RALPH_ALLOW_SYSTEM_CHANGES:-0}

# Normalize HOME/CODEX_HOME so Codex can create sessions reliably.
if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
  USER_HOME=$(eval echo "~${USER}")
  if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
    export HOME="$USER_HOME"
  fi
fi
if [ -n "$RALPH_CODEX_HOME" ]; then
  export CODEX_HOME="$RALPH_CODEX_HOME"
elif [ -z "$CODEX_HOME" ]; then
  export CODEX_HOME="$HOME/.codex"
fi

can_write_dir() {
  local dir="$1"
  mkdir -p "$dir" 2>/dev/null || return 1
  local test_file="$dir/.ralph_write_test.$$"
  : > "$test_file" 2>/dev/null || return 1
  rm -f "$test_file" 2>/dev/null || true
  return 0
}

if ! can_write_dir "$CODEX_HOME/sessions"; then
  FALLBACK_CODEX_HOME="$SCRIPT_DIR/.codex"
  export CODEX_HOME="$FALLBACK_CODEX_HOME"
  if ! can_write_dir "$CODEX_HOME/sessions"; then
    echo "Warning: CODEX_HOME not writable at $CODEX_HOME (and fallback failed)" >&2
  else
    echo "Warning: CODEX_HOME not writable; falling back to $CODEX_HOME" >&2
  fi
fi

if [ -n "$RALPH_CODEX_ENABLE_NETWORK" ]; then
  CODEX_FLAGS="$CODEX_FLAGS --config sandbox_workspace_write.network_access=true"
fi

if [ -n "$RALPH_CODEX_ADD_DIRS" ]; then
  OLD_IFS="$IFS"
  IFS=":"
  for dir in $RALPH_CODEX_ADD_DIRS; do
    CODEX_FLAGS="$CODEX_FLAGS --add-dir $dir"
  done
  IFS="$OLD_IFS"
fi

# Prefer streaming output to the terminal when available; otherwise append to log.
TEE_ARGS=()
FOLLOW_LOG=""
if [ -w /dev/tty ] && [ -t 1 ]; then
  TEE_ARGS=("/dev/tty")
else
  TEE_ARGS=("-a" "$LOG_FILE")
  touch "$LOG_FILE"
  echo "No TTY detected; logging to $LOG_FILE"
  if [ -n "$RALPH_FOLLOW_LOG" ]; then
    FOLLOW_LOG=1
    tail -n 200 -f "$LOG_FILE" &
    TAIL_PID=$!
    trap 'kill "$TAIL_PID" 2>/dev/null' EXIT
  fi
fi

if [ -n "$RALPH_DEBUG_ENV" ]; then
  {
    echo "=== Ralph debug dump $(date) ==="
    echo "--- Identity"
    whoami || true
    id || true
    groups || true
    echo "--- Host"
    hostname || true
    uname -a || true
    echo "--- Shell"
    echo "SHELL=$SHELL"
    echo "BASH=$BASH"
    echo "ZSH_VERSION=$ZSH_VERSION"
    echo "BASH_VERSION=$BASH_VERSION"
    set -o || true
    echo "--- Process"
    echo "PID=$$"
    echo "PPID=$PPID"
    ps -o user= -p $$ 2>/dev/null || true
    tty || true
    umask || true
    ulimit -a || true
    echo "--- Paths"
    echo "PWD=$(pwd)"
    echo "SCRIPT_DIR=$SCRIPT_DIR"
    echo "HOME=$HOME"
    echo "CODEX_HOME=$CODEX_HOME"
    echo "XDG_STATE_HOME=$XDG_STATE_HOME"
    echo "XDG_DATA_HOME=$XDG_DATA_HOME"
    echo "XDG_CACHE_HOME=$XDG_CACHE_HOME"
    echo "PATH=$PATH"
    echo "--- Filesystem"
    df -h . "$SCRIPT_DIR" "$HOME" 2>/dev/null || true
    mount 2>/dev/null || true
    echo "--- Permissions"
    ls -ldOe "$SCRIPT_DIR" 2>/dev/null || true
    ls -ldOe "$HOME" "$CODEX_HOME" "$CODEX_HOME/sessions" 2>/dev/null || true
    stat -f "%Su %Sg %p %N" "$HOME" "$CODEX_HOME" "$CODEX_HOME/sessions" 2>/dev/null || true
    echo "--- Codex"
    command -v codex || true
    codex --version 2>/dev/null || true
    echo "--- Environment"
    env | sort
    echo "==============================="
  } >> "$LOG_FILE" 2>&1
fi

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    # Strip "ralph/" prefix from branch name for folder
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
    
    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"
    
    # Reset progress file for new run
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

echo "Starting Ralph - Max iterations: $MAX_ITERATIONS"

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Ralph Iteration $i of $MAX_ITERATIONS"
  echo "═══════════════════════════════════════════════════════"
  
  # Run the selected agent with the ralph prompt
  if [ "$AGENT" = "codex" ]; then
    LAST_MESSAGE_FILE=$(mktemp "${SCRIPT_DIR}/.codex-last-message.XXXXXX")
    if [ -n "$FOLLOW_LOG" ]; then
      cat "$SCRIPT_DIR/prompt.md" | "$CODEX_BIN" exec $CODEX_FLAGS --output-last-message "$LAST_MESSAGE_FILE" - 2>&1 | tee "${TEE_ARGS[@]}" >/dev/null || true
    else
      cat "$SCRIPT_DIR/prompt.md" | "$CODEX_BIN" exec $CODEX_FLAGS --output-last-message "$LAST_MESSAGE_FILE" - 2>&1 | tee "${TEE_ARGS[@]}" >/dev/null || true
    fi
    OUTPUT=$(cat "$LAST_MESSAGE_FILE" 2>/dev/null || true)
    rm -f "$LAST_MESSAGE_FILE" 2>/dev/null || true
  elif [ "$AGENT" = "amp" ]; then
    if [ -n "$FOLLOW_LOG" ]; then
      LOG_OFFSET=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
      cat "$SCRIPT_DIR/prompt.md" | amp $AMP_FLAGS 2>&1 | tee "${TEE_ARGS[@]}" >/dev/null || true
      OUTPUT=$(tail -c +$((LOG_OFFSET+1)) "$LOG_FILE" 2>/dev/null || true)
    else
      OUTPUT=$(cat "$SCRIPT_DIR/prompt.md" | amp $AMP_FLAGS 2>&1 | tee "${TEE_ARGS[@]}") || true
    fi
  else
    echo "Unknown RALPH_AGENT: $AGENT (expected 'amp' or 'codex')" >&2
    exit 2
  fi
  
  # Check for completion signal
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi
  
  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
