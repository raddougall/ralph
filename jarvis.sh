#!/bin/bash
# Jarvis - Long-running AI agent loop
# Usage: ./jarvis.sh [max_iterations]

set -e

MAX_ITERATIONS=${1:-10}
AGENT=${JARVIS_AGENT:-${RALPH_AGENT:-amp}}
AMP_FLAGS=${JARVIS_AMP_FLAGS:-${RALPH_AMP_FLAGS:---dangerously-allow-all}}
CODEX_GLOBAL_FLAGS=${JARVIS_CODEX_GLOBAL_FLAGS:-${RALPH_CODEX_GLOBAL_FLAGS:---sandbox workspace-write -a never}}
CODEX_FLAGS=${JARVIS_CODEX_FLAGS:-${RALPH_CODEX_FLAGS:---color never}}
CODEX_BIN=${JARVIS_CODEX_BIN:-${RALPH_CODEX_BIN:-codex}}
CLICKUP_STATUS_IN_PROGRESS=${CLICKUP_STATUS_IN_PROGRESS:-in progress}
CLICKUP_STATUS_TESTING=${CLICKUP_STATUS_TESTING:-testing}
CLICKUP_STATUS_WAITING=${CLICKUP_STATUS_WAITING:-waiting}
CLICKUP_STATUS_STUCK=${CLICKUP_STATUS_STUCK:-stuck}
CLICKUP_COMMENT_AUTHOR_LABEL=${CLICKUP_COMMENT_AUTHOR_LABEL:-Jarvis/Codex}
CLICKUP_LIST_ID_RESOLVED=""
CLICKUP_AUTH_HEADER=""
CURRENT_STORY_ID=""
CURRENT_TASK_ID=""
APPROVAL_QUEUE_BEFORE_LINES=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${JARVIS_PROJECT_DIR:-${RALPH_PROJECT_DIR:-$(pwd)}}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
PRD_FILE="$PROJECT_DIR/prd.json"
PROGRESS_FILE="$PROJECT_DIR/progress.txt"
ARCHIVE_DIR="$PROJECT_DIR/archive"
LAST_BRANCH_FILE="$PROJECT_DIR/.last-branch"
LOG_FILE="$PROJECT_DIR/jarvis.log"
APPROVAL_QUEUE_FILE="${JARVIS_APPROVAL_QUEUE_FILE:-${RALPH_APPROVAL_QUEUE_FILE:-$PROJECT_DIR/approval-queue.txt}}"
PROMPT_FILE="${JARVIS_PROMPT_FILE:-${RALPH_PROMPT_FILE:-}}"
if [ -z "$PROMPT_FILE" ]; then
  if [ -f "$PROJECT_DIR/.jarvis/prompt.md" ]; then
    PROMPT_FILE="$PROJECT_DIR/.jarvis/prompt.md"
  elif [ -f "$PROJECT_DIR/.ralph/prompt.md" ]; then
    PROMPT_FILE="$PROJECT_DIR/.ralph/prompt.md"
  else
    PROMPT_FILE="$SCRIPT_DIR/prompt.md"
  fi
fi
if [ ! -f "$PROMPT_FILE" ]; then
  echo "Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "MAX_ITERATIONS must be a non-negative integer (received: $MAX_ITERATIONS)" >&2
  exit 2
fi
if [ "$MAX_ITERATIONS" -lt 1 ]; then
  echo "Jarvis received max iterations of $MAX_ITERATIONS; nothing to run."
  exit 0
fi

# Ensure runtime is rooted in the target project directory.
cd "$PROJECT_DIR"

# Guardrail: block host-level package manager mutations unless explicitly allowed.
if [ -d "$SCRIPT_DIR/guard-bin" ]; then
  export PATH="$SCRIPT_DIR/guard-bin:$PATH"
fi

# This must be explicitly set to 1 only after user approval for host-level changes.
export JARVIS_ALLOW_SYSTEM_CHANGES=${JARVIS_ALLOW_SYSTEM_CHANGES:-${RALPH_ALLOW_SYSTEM_CHANGES:-0}}
# Backward-compat for existing guard script checks.
export RALPH_ALLOW_SYSTEM_CHANGES="${RALPH_ALLOW_SYSTEM_CHANGES:-$JARVIS_ALLOW_SYSTEM_CHANGES}"
export JARVIS_APPROVAL_QUEUE_FILE="$APPROVAL_QUEUE_FILE"
# Backward-compat for scripts/prompts that still read the legacy prefix.
export RALPH_APPROVAL_QUEUE_FILE="${RALPH_APPROVAL_QUEUE_FILE:-$JARVIS_APPROVAL_QUEUE_FILE}"

# Normalize HOME/CODEX_HOME so Codex can create sessions reliably.
if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
  USER_HOME=$(eval echo "~${USER}")
  if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
    export HOME="$USER_HOME"
  fi
fi

path_in_project() {
  local target="$1"
  case "$target" in
    "$PROJECT_DIR"|"$PROJECT_DIR"/*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_dir() {
  local dir="$1"
  mkdir -p "$dir" 2>/dev/null || true
  (cd "$dir" 2>/dev/null && pwd) || echo "$dir"
}

codex_home_can_sync_runtime() {
  local home_dir="$1"
  case "$home_dir" in
    "$PROJECT_DIR"|"$PROJECT_DIR"/*|/tmp/*|"$TMPDIR"*) return 0 ;;
    *) return 1 ;;
  esac
}

sync_codex_runtime_files() {
  local source_auth="$HOME/.codex/auth.json"
  local source_config="$HOME/.codex/config.toml"
  local target_auth="$CODEX_HOME/auth.json"
  local target_config="$CODEX_HOME/config.toml"

  if ! codex_home_can_sync_runtime "$CODEX_HOME"; then
    return 0
  fi

  mkdir -p "$CODEX_HOME" 2>/dev/null || true

  if [ -f "$source_auth" ]; then
    if [ ! -f "$target_auth" ] || [ "$source_auth" -nt "$target_auth" ]; then
      cp "$source_auth" "$target_auth" 2>/dev/null || true
    fi
  fi

  if [ -f "$source_config" ]; then
    if [ ! -f "$target_config" ] || [ "$source_config" -nt "$target_config" ]; then
      cp "$source_config" "$target_config" 2>/dev/null || true
    fi
  fi
}

load_project_clickup_env() {
  local clickup_env_file="${JARVIS_CLICKUP_ENV_FILE:-$PROJECT_DIR/scripts/clickup/.env.clickup}"

  if [ -f "$clickup_env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$clickup_env_file"
    set +a
  fi
}
has_clickup_config() {
  if [ -z "${CLICKUP_TOKEN:-}" ]; then
    return 1
  fi
  if [ -z "${CLICKUP_LIST_ID:-${CLICKUP_LIST_URL:-}}" ]; then
    return 1
  fi
  return 0
}

clickup_extract_list_id() {
  local input="$1"

  if [[ "$input" =~ /li/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi

  if [[ "$input" =~ ^[0-9]+$ ]]; then
    echo "$input"
    return
  fi

  echo ""
}

clickup_prepare_context() {
  local list_source

  CLICKUP_LIST_ID_RESOLVED=""
  CLICKUP_AUTH_HEADER=""

  if ! has_clickup_config; then
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  list_source="${CLICKUP_LIST_ID:-${CLICKUP_LIST_URL:-}}"
  CLICKUP_LIST_ID_RESOLVED="$(clickup_extract_list_id "$list_source")"
  if [ -z "$CLICKUP_LIST_ID_RESOLVED" ]; then
    return 1
  fi

  if [[ "$CLICKUP_TOKEN" == pk_* ]]; then
    CLICKUP_AUTH_HEADER="Authorization: $CLICKUP_TOKEN"
  else
    CLICKUP_AUTH_HEADER="Authorization: Bearer $CLICKUP_TOKEN"
  fi

  return 0
}

clickup_is_ready() {
  [ -n "$CLICKUP_LIST_ID_RESOLVED" ] && [ -n "$CLICKUP_AUTH_HEADER" ]
}

clickup_api_get() {
  local path="$1"
  curl -sS -H "$CLICKUP_AUTH_HEADER" -H "Content-Type: application/json" "${CLICKUP_API_BASE:-https://api.clickup.com/api/v2}$path"
}

clickup_api_put_status() {
  local task_id="$1"
  local status="$2"

  jq -n --arg status "$status" '{status:$status}' \
    | curl -sS -X PUT "${CLICKUP_API_BASE:-https://api.clickup.com/api/v2}/task/$task_id" \
      -H "$CLICKUP_AUTH_HEADER" \
      -H "Content-Type: application/json" \
      --data-binary @- >/dev/null
}

clickup_api_post_comment() {
  local task_id="$1"
  local comment="$2"

  jq -n --arg comment_text "$comment" '{comment_text:$comment_text, notify_all:false}'     | curl -sS -X POST "${CLICKUP_API_BASE:-https://api.clickup.com/api/v2}/task/$task_id/comment"       -H "$CLICKUP_AUTH_HEADER"       -H "Content-Type: application/json"       --data-binary @- >/dev/null
}

clickup_find_task_id_for_story() {
  local story_id="$1"
  local page=0
  local response
  local count
  local task_id

  while :; do
    response="$(clickup_api_get "/list/$CLICKUP_LIST_ID_RESOLVED/task?include_closed=true&page=$page")" || return 1
    count="$(jq -r '.tasks | length' <<<"$response" 2>/dev/null || echo 0)"
    if [ "$count" = "0" ]; then
      break
    fi

    task_id="$(jq -r --arg prefix "[$story_id] " '.tasks[] | select(.name | startswith($prefix)) | .id' <<<"$response" | head -n 1)"
    if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
      echo "$task_id"
      return 0
    fi

    page=$((page + 1))
  done

  return 1
}

next_unblocked_story_id() {
  jq -r '
    (.userStories // [])
    | map(select((.passes == false) and (((.notes // "") | startswith("BLOCKED:")) | not)))
    | sort_by(.priority // 999999)
    | .[0].id // empty
  ' "$PRD_FILE"
}

story_passes() {
  local story_id="$1"
  jq -e --arg story_id "$story_id" '.userStories[] | select(.id == $story_id and .passes == true)' "$PRD_FILE" >/dev/null 2>&1
}

story_note() {
  local story_id="$1"
  jq -r --arg story_id "$story_id" '.userStories[] | select(.id == $story_id) | .notes // ""' "$PRD_FILE" 2>/dev/null | head -n 1
}

record_approval_queue_lines() {
  if [ -f "$APPROVAL_QUEUE_FILE" ]; then
    APPROVAL_QUEUE_BEFORE_LINES="$(wc -l < "$APPROVAL_QUEUE_FILE" 2>/dev/null || echo 0)"
  else
    APPROVAL_QUEUE_BEFORE_LINES=0
  fi
}

new_approval_queue_entries_for_story() {
  local story_id="$1"
  local total_lines

  if [ ! -f "$APPROVAL_QUEUE_FILE" ]; then
    return 0
  fi

  total_lines="$(wc -l < "$APPROVAL_QUEUE_FILE" 2>/dev/null || echo 0)"
  if [ "$total_lines" -le "$APPROVAL_QUEUE_BEFORE_LINES" ]; then
    return 0
  fi

  tail -n "+$((APPROVAL_QUEUE_BEFORE_LINES + 1))" "$APPROVAL_QUEUE_FILE"     | grep -E "(\[$story_id\]|story=$story_id)" || true
}

extract_recovery_commit_command() {
  local story_id="$1"
  local command_line=""

  if [ ! -f "$APPROVAL_QUEUE_FILE" ]; then
    return 1
  fi

  command_line="$(grep -E "story=$story_id \| command=git add .*&& git commit -m " "$APPROVAL_QUEUE_FILE" | tail -n 1 | sed -E 's/^.*command=//; s/ \| reason=.*$//')"

  if [ -z "$command_line" ]; then
    command_line="$(grep -E "\[$story_id\] git add .*&& git commit -m " "$APPROVAL_QUEUE_FILE" | tail -n 1 | sed -E "s/^.*\[$story_id\] //; s/ \| .*$//")"
  fi

  if [ -z "$command_line" ]; then
    return 1
  fi

  echo "$command_line"
}

is_safe_recovery_command() {
  local command_line="$1"

  if [[ "$command_line" != git\ add*' && git commit -m '* ]]; then
    return 1
  fi

  case "$command_line" in
    *';'*|*'|'*|*'$('*|*'`'*) return 1 ;;
  esac

  return 0
}

run_git_commit_recovery() {
  local story_id="$1"
  local command_line
  local recovery_note
  local tmp_file

  command_line="$(extract_recovery_commit_command "$story_id" || true)"
  if [ -z "$command_line" ]; then
    return 1
  fi

  if ! is_safe_recovery_command "$command_line"; then
    echo "Warning: refusing unsafe recovery command for $story_id" >&2
    return 1
  fi

  if ! (cd "$PROJECT_DIR" && bash -lc "$command_line"); then
    return 1
  fi

  recovery_note="Committed by Jarvis runner after recovering nested git sandbox lock."
  tmp_file="$(mktemp)"
  jq --arg story_id "$story_id" --arg recovery_note "$recovery_note" '
    (.userStories[] | select(.id == $story_id) | .passes) = true
    | (.userStories[] | select(.id == $story_id) | .notes) |= (if ((. // "") | startswith("BLOCKED:")) then $recovery_note else . end)
  ' "$PRD_FILE" > "$tmp_file"
  mv "$tmp_file" "$PRD_FILE"

  {
    echo "## $(date -u '+%Y-%m-%d %H:%M:%S UTC') - $story_id"
    echo "Session: Jarvis commit recovery"
    echo "- Recovered commit after nested Codex sandbox blocked .git/index.lock."
    echo "- Executed queued git command from approval queue in runner context."
    echo "- Restored story state to passes=true in prd.json."
    echo "---"
  } >> "$PROGRESS_FILE"

  return 0
}

extract_host_from_url() {
  local input="$1"
  local host="$input"

  host="${host#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  echo "$host"
}

check_https_host_reachable() {
  local host="$1"
  local timeout_seconds="${JARVIS_NETWORK_PREFLIGHT_TIMEOUT_SECONDS:-${RALPH_NETWORK_PREFLIGHT_TIMEOUT_SECONDS:-8}}"

  if [ -z "$host" ]; then
    return 1
  fi

  curl -sS -I --max-time "$timeout_seconds" "https://$host" >/dev/null 2>&1
}

run_network_preflight() {
  local enabled="${JARVIS_NETWORK_PREFLIGHT:-${RALPH_NETWORK_PREFLIGHT:-1}}"
  local strict_mode="${JARVIS_NETWORK_PREFLIGHT_STRICT:-${RALPH_NETWORK_PREFLIGHT_STRICT:-1}}"
  local -a hosts=()
  local -a unique_hosts=()
  local -a failed_hosts=()
  local host

  if [ "$enabled" = "0" ]; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    if [ "$strict_mode" = "1" ]; then
      echo "Network preflight failed: curl is required but not available." >&2
      exit 2
    fi
    echo "Warning: skipping network preflight because curl is unavailable (set strict mode to fail instead)." >&2
    return 0
  fi

  if [ "$AGENT" = "codex" ]; then
    hosts+=("$(extract_host_from_url "${JARVIS_OPENAI_PREFLIGHT_URL:-${RALPH_OPENAI_PREFLIGHT_URL:-https://chatgpt.com}}")")
  fi

  if has_clickup_config; then
    hosts+=("$(extract_host_from_url "${CLICKUP_API_BASE:-https://api.clickup.com/api/v2}")")
  fi

  if [ -n "${JARVIS_NETWORK_PREFLIGHT_HOSTS:-${RALPH_NETWORK_PREFLIGHT_HOSTS:-}}" ]; then
    local old_ifs="$IFS"
    IFS=","
    for host in ${JARVIS_NETWORK_PREFLIGHT_HOSTS:-${RALPH_NETWORK_PREFLIGHT_HOSTS:-}}; do
      hosts+=("$host")
    done
    IFS="$old_ifs"
  fi

  for host in "${hosts[@]}"; do
    if [ -z "$host" ]; then
      continue
    fi
    local seen=0
    local existing
    for existing in "${unique_hosts[@]}"; do
      if [ "$existing" = "$host" ]; then
        seen=1
        break
      fi
    done
    if [ "$seen" -eq 0 ]; then
      unique_hosts+=("$host")
    fi
  done

  if [ "${#unique_hosts[@]}" -eq 0 ]; then
    return 0
  fi

  for host in "${unique_hosts[@]}"; do
    if ! check_https_host_reachable "$host"; then
      failed_hosts+=("$host")
    fi
  done

  if [ "${#failed_hosts[@]}" -eq 0 ]; then
    echo "Network preflight passed for: ${unique_hosts[*]}"
    return 0
  fi

  echo "Network preflight failed. Unreachable hosts: ${failed_hosts[*]}" >&2
  echo "This run context appears to block external DNS/network (OpenAI/ClickUp)." >&2
  echo "Re-run with network-enabled permissions or disable strict mode for diagnostics." >&2

  if [ "$strict_mode" = "1" ]; then
    exit 2
  fi

  echo "Warning: continuing despite failed network preflight (JARVIS_NETWORK_PREFLIGHT_STRICT=0)." >&2
  return 0
}

run_clickup_prd_pull_sync() {
  local should_sync="${JARVIS_CLICKUP_SYNC_ON_START:-${RALPH_CLICKUP_SYNC_ON_START:-1}}"
  local strict_sync="${JARVIS_CLICKUP_SYNC_STRICT:-${RALPH_CLICKUP_SYNC_STRICT:-0}}"
  local sync_script="$PROJECT_DIR/scripts/clickup/sync_clickup_to_prd.sh"

  if [ "$should_sync" = "0" ]; then
    return 0
  fi

  if ! has_clickup_config; then
    echo "ClickUp pre-sync skipped: set CLICKUP_TOKEN and CLICKUP_LIST_ID/CLICKUP_LIST_URL to enable."
    return 0
  fi

  if [ ! -x "$sync_script" ]; then
    echo "ClickUp pre-sync skipped: script not found or not executable at $sync_script"
    return 0
  fi

  echo "Running ClickUp -> local PRD sync..."
  if PRD_FILE="$PRD_FILE" PROGRESS_FILE="$PROGRESS_FILE" "$sync_script"; then
    echo "ClickUp pre-sync complete."
    return 0
  fi

  if [ "$strict_sync" = "1" ]; then
    echo "ClickUp pre-sync failed and strict mode is enabled (JARVIS_CLICKUP_SYNC_STRICT=1)." >&2
    exit 1
  fi

  echo "Warning: ClickUp pre-sync failed; continuing run (set JARVIS_CLICKUP_SYNC_STRICT=1 to fail-fast)." >&2
  return 0
}

run_project_launcher_sync() {
  local should_sync="${JARVIS_PROJECT_SYNC_ON_START:-${RALPH_PROJECT_SYNC_ON_START:-1}}"
  local strict_sync="${JARVIS_PROJECT_SYNC_STRICT:-${RALPH_PROJECT_SYNC_STRICT:-0}}"
  local installer_script="$SCRIPT_DIR/scripts/install-project-launcher.sh"

  if [ "$should_sync" = "0" ]; then
    return 0
  fi

  if [ "$PROJECT_DIR" = "$SCRIPT_DIR" ]; then
    return 0
  fi

  if [ ! -x "$installer_script" ]; then
    echo "Project launcher sync skipped: installer not found or not executable at $installer_script"
    return 0
  fi

  echo "Syncing project launcher/wrappers from Jarvis master..."
  if "$installer_script" "$PROJECT_DIR" >/dev/null 2>&1; then
    echo "Project launcher sync complete."
    return 0
  fi

  if [ "$strict_sync" = "1" ]; then
    echo "Project launcher sync failed and strict mode is enabled (JARVIS_PROJECT_SYNC_STRICT=1)." >&2
    exit 1
  fi

  echo "Warning: project launcher sync failed; continuing run (set JARVIS_PROJECT_SYNC_STRICT=1 to fail-fast)." >&2
  return 0
}

requested_codex_home="${JARVIS_CODEX_HOME:-${RALPH_CODEX_HOME:-${CODEX_HOME:-}}}"
if [ -n "$requested_codex_home" ]; then
  resolved_codex_home="$(resolve_dir "$requested_codex_home")"
  if path_in_project "$resolved_codex_home"; then
    export CODEX_HOME="$resolved_codex_home"
  else
    export CODEX_HOME="$PROJECT_DIR/.codex"
    echo "Warning: ignoring non-project CODEX_HOME ($resolved_codex_home); using $CODEX_HOME" >&2
  fi
else
  export CODEX_HOME="$PROJECT_DIR/.codex"
fi

sync_codex_runtime_files

can_write_dir() {
  local dir="$1"
  mkdir -p "$dir" 2>/dev/null || return 1
  local test_file="$dir/.jarvis_write_test.$$"
  : > "$test_file" 2>/dev/null || return 1
  rm -f "$test_file" 2>/dev/null || true
  return 0
}

if ! can_write_dir "$CODEX_HOME/sessions"; then
  FALLBACK_CODEX_HOME_RAW="${JARVIS_CODEX_FALLBACK_HOME:-${RALPH_CODEX_FALLBACK_HOME:-/tmp/jarvis-codex-$(echo "$PROJECT_DIR" | cksum | awk '{print $1}')}}"
  FALLBACK_CODEX_HOME_RESOLVED="$(resolve_dir "$FALLBACK_CODEX_HOME_RAW")"
  case "$FALLBACK_CODEX_HOME_RESOLVED" in
    /tmp/*|"$TMPDIR"*) ;;
    *)
      FALLBACK_CODEX_HOME_RESOLVED="/tmp/jarvis-codex-$(echo "$PROJECT_DIR" | cksum | awk '{print $1}')"
      ;;
  esac
  export CODEX_HOME="$FALLBACK_CODEX_HOME_RESOLVED"
  sync_codex_runtime_files
  if ! can_write_dir "$CODEX_HOME/sessions"; then
    echo "Warning: CODEX_HOME not writable at $CODEX_HOME (and fallback failed)" >&2
  else
    echo "Warning: CODEX_HOME not writable; falling back to $CODEX_HOME" >&2
  fi
fi

if [ -n "${JARVIS_CODEX_ENABLE_NETWORK:-${RALPH_CODEX_ENABLE_NETWORK:-}}" ] && echo "$CODEX_GLOBAL_FLAGS" | grep -q -- "--sandbox workspace-write"; then
  CODEX_FLAGS="$CODEX_FLAGS --config sandbox_workspace_write.network_access=true"
fi

if [ -n "${JARVIS_CODEX_ADD_DIRS:-${RALPH_CODEX_ADD_DIRS:-}}" ]; then
  OLD_IFS="$IFS"
  IFS=":"
  for dir in ${JARVIS_CODEX_ADD_DIRS:-${RALPH_CODEX_ADD_DIRS:-}}; do
    resolved_add_dir="$(resolve_dir "$dir")"
    if path_in_project "$resolved_add_dir"; then
      CODEX_FLAGS="$CODEX_FLAGS --add-dir $resolved_add_dir"
    else
      echo "Warning: ignoring non-project add-dir ($resolved_add_dir)" >&2
    fi
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
  if [ -n "${JARVIS_FOLLOW_LOG:-${RALPH_FOLLOW_LOG:-}}" ]; then
    FOLLOW_LOG=1
    tail -n 200 -f "$LOG_FILE" &
    TAIL_PID=$!
    trap 'kill "$TAIL_PID" 2>/dev/null' EXIT
  fi
fi

if [ -n "${JARVIS_DEBUG_ENV:-${RALPH_DEBUG_ENV:-}}" ]; then
  {
    echo "=== Jarvis debug dump $(date) ==="
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
    echo "PROJECT_DIR=$PROJECT_DIR"
    echo "PROMPT_FILE=$PROMPT_FILE"
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

load_project_clickup_env
run_network_preflight
run_project_launcher_sync
run_clickup_prd_pull_sync
clickup_prepare_context || true

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    # Strip "jarvis/" or "ralph/" prefix from branch name for folder
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed -E 's|^(jarvis|ralph)/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
    
    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"
    
    # Reset progress file for new run
    echo "# Jarvis Progress Log" > "$PROGRESS_FILE"
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
  echo "# Jarvis Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

if [ ! -f "$APPROVAL_QUEUE_FILE" ]; then
  {
    echo "# Jarvis Approval Queue"
    echo "# Commands requiring manual approval should be appended by story iterations."
    echo "# Format suggestion: [timestamp] [story] command | reason | fallback-attempted"
    echo "---"
  } > "$APPROVAL_QUEUE_FILE"
fi

echo "Starting Jarvis - Max iterations: $MAX_ITERATIONS"

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Jarvis Iteration $i of $MAX_ITERATIONS"
  echo "═══════════════════════════════════════════════════════"
  
  CURRENT_STORY_ID="$(next_unblocked_story_id)"
  CURRENT_TASK_ID=""
  record_approval_queue_lines

  if clickup_is_ready && [ -n "$CURRENT_STORY_ID" ]; then
    CURRENT_TASK_ID="$(clickup_find_task_id_for_story "$CURRENT_STORY_ID" || true)"
    if [ -n "$CURRENT_TASK_ID" ]; then
      clickup_api_put_status "$CURRENT_TASK_ID" "$CLICKUP_STATUS_IN_PROGRESS" || true
    fi
  fi

  # Run the selected agent with the Jarvis prompt
  if [ "$AGENT" = "codex" ]; then
    LAST_MESSAGE_FILE=$(mktemp "${PROJECT_DIR}/.codex-last-message.XXXXXX")
    if [ -n "$FOLLOW_LOG" ]; then
      cat "$PROMPT_FILE" | "$CODEX_BIN" $CODEX_GLOBAL_FLAGS exec $CODEX_FLAGS --output-last-message "$LAST_MESSAGE_FILE" - 2>&1 | tee "${TEE_ARGS[@]}" >/dev/null || true
    else
      cat "$PROMPT_FILE" | "$CODEX_BIN" $CODEX_GLOBAL_FLAGS exec $CODEX_FLAGS --output-last-message "$LAST_MESSAGE_FILE" - 2>&1 | tee "${TEE_ARGS[@]}" >/dev/null || true
    fi
    OUTPUT=$(cat "$LAST_MESSAGE_FILE" 2>/dev/null || true)
    rm -f "$LAST_MESSAGE_FILE" 2>/dev/null || true
  elif [ "$AGENT" = "amp" ]; then
    if [ -n "$FOLLOW_LOG" ]; then
      LOG_OFFSET=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
      cat "$PROMPT_FILE" | amp $AMP_FLAGS 2>&1 | tee "${TEE_ARGS[@]}" >/dev/null || true
      OUTPUT=$(tail -c +$((LOG_OFFSET+1)) "$LOG_FILE" 2>/dev/null || true)
    else
      OUTPUT=$(cat "$PROMPT_FILE" | amp $AMP_FLAGS 2>&1 | tee "${TEE_ARGS[@]}") || true
    fi
  else
    echo "Unknown JARVIS_AGENT: $AGENT (expected 'amp' or 'codex')" >&2
    exit 2
  fi
  
  # Check for completion signal
  if echo "$OUTPUT" | grep -q "sandbox: read-only"; then
    echo ""
    echo "Jarvis detected a read-only Codex sandbox."
    echo "Project runs require workspace-write inside: $PROJECT_DIR"
    echo "Check project/local env overrides for JARVIS_CODEX_GLOBAL_FLAGS and remove any read-only sandbox setting."
    exit 2
  fi

  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Jarvis completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  if echo "$OUTPUT" | grep -q "<promise>BLOCKED</promise>"; then
    RECOVERED=0

    if [ -n "$CURRENT_STORY_ID" ] && echo "$OUTPUT" | grep -q ".git/index.lock"; then
      if run_git_commit_recovery "$CURRENT_STORY_ID"; then
        RECOVERED=1
        if clickup_is_ready && [ -n "$CURRENT_TASK_ID" ]; then
          clickup_api_put_status "$CURRENT_TASK_ID" "$CLICKUP_STATUS_TESTING" || true
          clickup_api_post_comment "$CURRENT_TASK_ID" "[$CLICKUP_COMMENT_AUTHOR_LABEL][$CURRENT_STORY_ID][testing][jarvis-recovery]
Changed:
- Jarvis recovered commit after nested sandbox blocked .git/index.lock.
Outcome:
- Commit recovered in runner context; task returned to testing." || true
        fi
      fi
    fi

    if [ "$RECOVERED" = "1" ]; then
      echo ""
      echo "Jarvis recovered blocked git commit for $CURRENT_STORY_ID; continuing."
      sleep 2
      continue
    fi

    NEEDS_USER=0
    if echo "$OUTPUT" | grep -Eqi "waiting for approvals|manual approval|requires approval|approval queue"; then
      NEEDS_USER=1
    else
      if new_approval_queue_entries_for_story "$CURRENT_STORY_ID" | grep -Eqi "approval|approve"; then
        NEEDS_USER=1
      fi
    fi

    if clickup_is_ready && [ -n "$CURRENT_TASK_ID" ]; then
      BLOCK_NOTE="$(story_note "$CURRENT_STORY_ID")"
      if [ "$NEEDS_USER" = "1" ]; then
        clickup_api_put_status "$CURRENT_TASK_ID" "$CLICKUP_STATUS_WAITING" || true
        clickup_api_post_comment "$CURRENT_TASK_ID" "[$CLICKUP_COMMENT_AUTHOR_LABEL][$CURRENT_STORY_ID][waiting]
Outcome:
- Story blocked waiting for user action/approval.
Reason:
- ${BLOCK_NOTE:-Blocked waiting for approval}." || true
      else
        clickup_api_put_status "$CURRENT_TASK_ID" "$CLICKUP_STATUS_STUCK" || true
        clickup_api_post_comment "$CURRENT_TASK_ID" "[$CLICKUP_COMMENT_AUTHOR_LABEL][$CURRENT_STORY_ID][stuck]
Outcome:
- Story is stuck due to execution/runtime blocker.
Reason:
- ${BLOCK_NOTE:-Blocked by runtime error}." || true
      fi
    fi

    echo ""
    if [ "$NEEDS_USER" = "1" ]; then
      echo "Jarvis marked $CURRENT_STORY_ID as waiting and will continue to next iteration."
    else
      echo "Jarvis marked $CURRENT_STORY_ID as stuck and will continue to next iteration."
    fi

    sleep 2
    continue
  fi
  
  if clickup_is_ready && [ -n "$CURRENT_STORY_ID" ] && [ -n "$CURRENT_TASK_ID" ]; then
    if story_passes "$CURRENT_STORY_ID"; then
      clickup_api_put_status "$CURRENT_TASK_ID" "$CLICKUP_STATUS_TESTING" || true
    fi
  fi

  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Jarvis reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
