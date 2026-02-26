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
BRANCH_POLICY_RAW=${JARVIS_BRANCH_POLICY:-${RALPH_BRANCH_POLICY:-prd}}
MAIN_BRANCH=${JARVIS_MAIN_BRANCH:-${RALPH_MAIN_BRANCH:-main}}
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
CODEX_STREAM_FAILURE_STREAK=0
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

case "$BRANCH_POLICY_RAW" in
  prd|main|current)
    BRANCH_POLICY="$BRANCH_POLICY_RAW"
    ;;
  *)
    echo "Invalid JARVIS_BRANCH_POLICY='$BRANCH_POLICY_RAW' (expected: prd, main, current)" >&2
    exit 2
    ;;
esac

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

story_title() {
  local story_id="$1"
  jq -r --arg story_id "$story_id" '.userStories[] | select(.id == $story_id) | .title // ""' "$PRD_FILE" 2>/dev/null | head -n 1
}

story_priority() {
  local story_id="$1"
  jq -r --arg story_id "$story_id" '.userStories[] | select(.id == $story_id) | .priority // empty' "$PRD_FILE" 2>/dev/null | head -n 1
}

snapshot_non_target_stories() {
  local story_id="$1"
  local output_file="$2"

  jq -c --arg story_id "$story_id" '
    (.userStories // [])
    | map(select(.id != $story_id))
    | map({
        id: .id,
        passes: (.passes // false),
        notes: (.notes // ""),
        title: (.title // ""),
        priority: (.priority // null),
        description: (.description // ""),
        acceptanceCriteria: (.acceptanceCriteria // [])
      })
    | sort_by(.id)
  ' "$PRD_FILE" > "$output_file"
}

guard_single_story_scope() {
  local story_id="$1"
  local pre_snapshot_file="$2"
  local post_snapshot_file
  local changed_ids

  post_snapshot_file="$(mktemp)"
  snapshot_non_target_stories "$story_id" "$post_snapshot_file"

  if cmp -s "$pre_snapshot_file" "$post_snapshot_file"; then
    rm -f "$post_snapshot_file" 2>/dev/null || true
    return 0
  fi

  changed_ids="$(
    jq -r --slurpfile before "$pre_snapshot_file" --slurpfile after "$post_snapshot_file" '
      ($before[0] // []) as $b
      | ($after[0] // []) as $a
      | (($b | map({key: .id, value: .}) | from_entries) // {}) as $bm
      | (($a | map({key: .id, value: .}) | from_entries) // {}) as $am
      | ((($bm | keys_unsorted) + ($am | keys_unsorted)) | unique) as $ids
      | $ids[]
      | select(($bm[.] // null) != ($am[.] // null))
    ' | paste -sd, -
  )"

  echo "Jarvis guard failed: iteration pinned to $story_id but non-target story state changed." >&2
  if [ -n "$changed_ids" ]; then
    echo "Changed non-target stories: $changed_ids" >&2
  fi
  echo "Refusing to continue because only the selected story may be modified in this iteration." >&2
  rm -f "$post_snapshot_file" 2>/dev/null || true
  return 1
}

build_iteration_prompt_file() {
  local story_id="$1"
  local story_title_value="$2"
  local story_priority_value="$3"
  local output_file="$4"

  cp "$PROMPT_FILE" "$output_file"
  {
    echo ""
    echo "## Iteration Pin (Mandatory)"
    echo "Implement ONLY story ID: $story_id"
    echo "Pinned story title: ${story_title_value:-unknown}"
    echo "Pinned story priority: ${story_priority_value:-unknown}"
    echo "Do not modify any other story in prd.json (including passes/notes updates)."
  } >> "$output_file"
}

cleanup_iteration_temp_files() {
  local prompt_file="$1"
  local snapshot_file="$2"
  local last_message_file="$3"
  local stream_log_file="$4"

  if [ -n "$prompt_file" ] && [ "$prompt_file" != "$PROMPT_FILE" ]; then
    rm -f "$prompt_file" 2>/dev/null || true
  fi
  [ -n "$snapshot_file" ] && rm -f "$snapshot_file" 2>/dev/null || true
  [ -n "$last_message_file" ] && rm -f "$last_message_file" 2>/dev/null || true
  [ -n "$stream_log_file" ] && rm -f "$stream_log_file" 2>/dev/null || true
}

story_is_blocked() {
  local story_id="$1"
  jq -e --arg story_id "$story_id" '.userStories[] | select(.id == $story_id and ((.notes // "") | startswith("BLOCKED:")))' "$PRD_FILE" >/dev/null 2>&1
}
mark_story_blocked() {
  local story_id="$1"
  local reason="$2"
  local blocked_note="BLOCKED: $reason"
  local tmp_file

  if ! jq -e --arg story_id "$story_id" '.userStories[] | select(.id == $story_id)' "$PRD_FILE" >/dev/null 2>&1; then
    return 1
  fi

  tmp_file="$(mktemp)"
  jq --arg story_id "$story_id" --arg blocked_note "$blocked_note" '
    (.userStories[] | select(.id == $story_id) | .passes) = false
    | (.userStories[] | select(.id == $story_id) | .notes) = $blocked_note
  ' "$PRD_FILE" > "$tmp_file"
  mv "$tmp_file" "$PRD_FILE"

  return 0
}

output_requests_user_input() {
  local output="$1"

  echo "$output" | grep -Eqi "i need your direction|i need your input|choose one:|please choose one|which option|how would you like to proceed|awaiting your confirmation|requires your confirmation"
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
    command_line="$(grep -E "story=$story_id\\\\ncommand=git add .*&& git commit -m " "$APPROVAL_QUEUE_FILE" | tail -n 1 | sed -E 's/^.*\\\\ncommand=//; s/\\\\nreason=.*$//')"
  fi
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

run_clickup_directives_sync() {
  local sync_reason="${1:-manual}"
  local should_sync="${JARVIS_CLICKUP_DIRECTIVES_SYNC_ON_START:-${RALPH_CLICKUP_DIRECTIVES_SYNC_ON_START:-0}}"
  local strict_sync="${JARVIS_CLICKUP_DIRECTIVES_SYNC_STRICT:-${RALPH_CLICKUP_DIRECTIVES_SYNC_STRICT:-0}}"
  local branch_policy="${JARVIS_CLICKUP_DIRECTIVES_SYNC_BRANCH_POLICY:-${RALPH_CLICKUP_DIRECTIVES_SYNC_BRANCH_POLICY:-main_only}}"
  local sync_script="$PROJECT_DIR/scripts/clickup/sync_jarvis_directives_to_clickup.sh"
  local current_branch=""

  if [ "$should_sync" = "0" ]; then
    return 0
  fi

  if ! has_clickup_config; then
    echo "Directives sync skipped: set CLICKUP_TOKEN and CLICKUP_LIST_ID/CLICKUP_LIST_URL to enable."
    return 0
  fi

  if [ ! -x "$sync_script" ]; then
    echo "Directives sync skipped: script not found or not executable at $sync_script"
    return 0
  fi

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi

  if [ "$branch_policy" = "main_only" ] && [ -n "$current_branch" ] && [ "$current_branch" != "$MAIN_BRANCH" ]; then
    echo "Directives sync skipped on branch '$current_branch' (policy: main_only, main: '$MAIN_BRANCH')."
    return 0
  fi

  echo "Running Jarvis directives -> ClickUp sync ($sync_reason)..."
  if "$sync_script"; then
    echo "Jarvis directives sync complete."
    return 0
  fi

  if [ "$strict_sync" = "1" ]; then
    echo "Jarvis directives sync failed and strict mode is enabled (JARVIS_CLICKUP_DIRECTIVES_SYNC_STRICT=1)." >&2
    exit 1
  fi

  echo "Warning: Jarvis directives sync failed; continuing run (set JARVIS_CLICKUP_DIRECTIVES_SYNC_STRICT=1 to fail-fast)." >&2
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

enforce_branch_policy_once() {
  local current_branch=""

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  if [ "$BRANCH_POLICY" != "main" ]; then
    return 0
  fi

  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ "$current_branch" = "$MAIN_BRANCH" ]; then
    return 0
  fi

  echo "Branch policy requires direct work on '$MAIN_BRANCH' (current: '${current_branch:-unknown}')."
  if git switch "$MAIN_BRANCH" >/dev/null 2>&1 || git checkout "$MAIN_BRANCH" >/dev/null 2>&1; then
    echo "Switched to '$MAIN_BRANCH' per branch policy."
    return 0
  fi

  echo "Branch policy failed: unable to switch to '$MAIN_BRANCH'." >&2
  echo "Recovery: create/restore '$MAIN_BRANCH' locally and rerun, or set JARVIS_BRANCH_POLICY=current for this run." >&2
  return 1
}

run_git_preflight() {
  local enabled="${JARVIS_GIT_PREFLIGHT:-${RALPH_GIT_PREFLIGHT:-1}}"
  local branch_probe_enabled="${JARVIS_GIT_PREFLIGHT_BRANCH_PROBE:-${RALPH_GIT_PREFLIGHT_BRANCH_PROBE:-}}"
  local git_dir=""
  local probe_file=""
  local temp_branch=""
  local branch_error=""

  if [ "$enabled" = "0" ]; then
    return 0
  fi

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Git preflight failed: project is not a git working tree." >&2
    return 1
  fi

  git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
  if [ -z "$git_dir" ]; then
    echo "Git preflight failed: unable to resolve .git directory." >&2
    return 1
  fi

  probe_file="$git_dir/.jarvis-write-test.$$"
  if ! : > "$probe_file" 2>/dev/null; then
    echo "Git preflight failed: cannot write inside $git_dir (index/refs locks will fail)." >&2
    echo "Recovery: ensure this run has filesystem permissions to write .git/index and .git/refs, then re-run Jarvis." >&2
    return 1
  fi
  rm -f "$probe_file" 2>/dev/null || true

  if [ -z "$branch_probe_enabled" ]; then
    if [ "$BRANCH_POLICY" = "prd" ]; then
      branch_probe_enabled=1
    else
      branch_probe_enabled=0
    fi
  fi

  if [ "$branch_probe_enabled" = "1" ]; then
    temp_branch="jarvis-preflight-$$-$RANDOM"
    if ! branch_error="$(git branch --no-track "$temp_branch" 2>&1)"; then
      echo "Git preflight failed: cannot create branch '$temp_branch'." >&2
      echo "$branch_error" >&2
      if echo "$branch_error" | grep -qi "cannot lock ref"; then
        echo "Recovery: fix ref namespace conflicts under .git/refs/heads, then re-run." >&2
      else
        echo "Recovery: verify git write permissions and ref health, then re-run Jarvis." >&2
      fi
      return 1
    fi

    if ! git branch -D "$temp_branch" >/dev/null 2>&1; then
      echo "Git preflight failed: created temp branch '$temp_branch' but could not delete it." >&2
      echo "Recovery: delete the temp branch manually ('git branch -D $temp_branch') and check git ref permissions." >&2
      return 1
    fi
  fi

  return 0
}

codex_stream_disconnect_retryable() {
  local log_file="$1"
  local codex_status="$2"
  local output="$3"

  if [ ! -s "$log_file" ]; then
    return 1
  fi

  if ! grep -Eqi "(codex/responses|stream.*disconnect|disconnect.*stream|reconnect|connection.*(closed|lost|reset)|ECONNRESET|EOF while reading)" "$log_file"; then
    return 1
  fi

  if [ "$codex_status" -eq 0 ] && [ -n "$(echo "$output" | tr -d '[:space:]')" ]; then
    return 1
  fi

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
run_clickup_directives_sync "run-start"
clickup_prepare_context || true

echo "Branch policy for this run: $BRANCH_POLICY (main branch: $MAIN_BRANCH)"
if ! enforce_branch_policy_once; then
  exit 2
fi

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    # Strip "jarvis/" or "ralph/" prefix from branch name for folder
    FOLDER_NAME="$LAST_BRANCH"
    FOLDER_NAME="${FOLDER_NAME#jarvis/}"
    FOLDER_NAME="${FOLDER_NAME#ralph/}"
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
  CURRENT_STORY_TITLE=""
  CURRENT_STORY_PRIORITY=""
  ITERATION_PROMPT_FILE="$PROMPT_FILE"
  PRE_RUN_STORY_SNAPSHOT_FILE=""
  LAST_MESSAGE_FILE=""
  STREAM_LOG_FILE=""
  record_approval_queue_lines
  ITERATION_HEAD_BEFORE="$(git rev-parse HEAD 2>/dev/null || true)"

  if [ -n "$CURRENT_STORY_ID" ]; then
    CURRENT_STORY_TITLE="$(story_title "$CURRENT_STORY_ID")"
    CURRENT_STORY_PRIORITY="$(story_priority "$CURRENT_STORY_ID")"
    echo "Selected story: $CURRENT_STORY_ID | title: ${CURRENT_STORY_TITLE:-unknown} | priority: ${CURRENT_STORY_PRIORITY:-unknown}"

    PRE_RUN_STORY_SNAPSHOT_FILE="$(mktemp)"
    snapshot_non_target_stories "$CURRENT_STORY_ID" "$PRE_RUN_STORY_SNAPSHOT_FILE"

    ITERATION_PROMPT_FILE="$(mktemp "${PROJECT_DIR}/.jarvis-iteration-prompt.XXXXXX")"
    build_iteration_prompt_file "$CURRENT_STORY_ID" "$CURRENT_STORY_TITLE" "$CURRENT_STORY_PRIORITY" "$ITERATION_PROMPT_FILE"
  else
    echo "No unblocked story selected; running with base prompt."
  fi

  if ! run_git_preflight; then
    echo ""
    echo "Jarvis aborted before story work due to git preflight failure."
    echo "No story edits were attempted in this iteration."
    cleanup_iteration_temp_files "$ITERATION_PROMPT_FILE" "$PRE_RUN_STORY_SNAPSHOT_FILE" "$LAST_MESSAGE_FILE" "$STREAM_LOG_FILE"
    exit 2
  fi

  if clickup_is_ready && [ -n "$CURRENT_STORY_ID" ]; then
    CURRENT_TASK_ID="$(clickup_find_task_id_for_story "$CURRENT_STORY_ID" || true)"
    if [ -n "$CURRENT_TASK_ID" ]; then
      clickup_api_put_status "$CURRENT_TASK_ID" "$CLICKUP_STATUS_IN_PROGRESS" || true
    fi
  fi

  # Run the selected agent with the Jarvis prompt
  if [ "$AGENT" = "codex" ]; then
    LAST_MESSAGE_FILE=$(mktemp "${PROJECT_DIR}/.codex-last-message.XXXXXX")
    STREAM_LOG_FILE=$(mktemp "${PROJECT_DIR}/.codex-stream-log.XXXXXX")
    set +e
    cat "$ITERATION_PROMPT_FILE" | "$CODEX_BIN" $CODEX_GLOBAL_FLAGS exec $CODEX_FLAGS --output-last-message "$LAST_MESSAGE_FILE" - 2>&1 | tee "${TEE_ARGS[@]}" "$STREAM_LOG_FILE" >/dev/null
    CODEX_CMD_STATUS=${PIPESTATUS[1]}
    set -e
    OUTPUT=$(cat "$LAST_MESSAGE_FILE" 2>/dev/null || true)
    if codex_stream_disconnect_retryable "$STREAM_LOG_FILE" "$CODEX_CMD_STATUS" "$OUTPUT"; then
      CODEX_STREAM_FAILURE_STREAK=$((CODEX_STREAM_FAILURE_STREAK + 1))
      echo ""
      echo "Jarvis detected Codex stream disconnect (${CODEX_STREAM_FAILURE_STREAK} consecutive); treating as retryable infrastructure failure."
      if [ "$CODEX_STREAM_FAILURE_STREAK" -gt 1 ]; then
        echo "Connectivity remains unstable (codex/responses stream retries). Story state is unchanged; retrying next iteration."
      fi
      cleanup_iteration_temp_files "$ITERATION_PROMPT_FILE" "$PRE_RUN_STORY_SNAPSHOT_FILE" "$LAST_MESSAGE_FILE" "$STREAM_LOG_FILE"
      sleep 2
      continue
    fi
    CODEX_STREAM_FAILURE_STREAK=0
  elif [ "$AGENT" = "amp" ]; then
    if [ -n "$FOLLOW_LOG" ]; then
      LOG_OFFSET=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
      cat "$ITERATION_PROMPT_FILE" | amp $AMP_FLAGS 2>&1 | tee "${TEE_ARGS[@]}" >/dev/null || true
      OUTPUT=$(tail -c +$((LOG_OFFSET+1)) "$LOG_FILE" 2>/dev/null || true)
    else
      OUTPUT=$(cat "$ITERATION_PROMPT_FILE" | amp $AMP_FLAGS 2>&1 | tee "${TEE_ARGS[@]}") || true
    fi
  else
    echo "Unknown JARVIS_AGENT: $AGENT (expected 'amp' or 'codex')" >&2
    cleanup_iteration_temp_files "$ITERATION_PROMPT_FILE" "$PRE_RUN_STORY_SNAPSHOT_FILE" "$LAST_MESSAGE_FILE" "$STREAM_LOG_FILE"
    exit 2
  fi

  if [ -n "$CURRENT_STORY_ID" ] && [ -n "$PRE_RUN_STORY_SNAPSHOT_FILE" ]; then
    if ! guard_single_story_scope "$CURRENT_STORY_ID" "$PRE_RUN_STORY_SNAPSHOT_FILE"; then
      cleanup_iteration_temp_files "$ITERATION_PROMPT_FILE" "$PRE_RUN_STORY_SNAPSHOT_FILE" "$LAST_MESSAGE_FILE" "$STREAM_LOG_FILE"
      exit 2
    fi
  fi

  ITERATION_HEAD_AFTER="$(git rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$ITERATION_HEAD_BEFORE" ] && [ -n "$ITERATION_HEAD_AFTER" ] && [ "$ITERATION_HEAD_BEFORE" != "$ITERATION_HEAD_AFTER" ]; then
    run_clickup_directives_sync "post-commit"
  fi
  
  # Check for completion signal
  if echo "$OUTPUT" | grep -q "sandbox: read-only"; then
    echo ""
    echo "Jarvis detected a read-only Codex sandbox."
    echo "Project runs require workspace-write inside: $PROJECT_DIR"
    echo "Check project/local env overrides for JARVIS_CODEX_GLOBAL_FLAGS and remove any read-only sandbox setting."
    cleanup_iteration_temp_files "$ITERATION_PROMPT_FILE" "$PRE_RUN_STORY_SNAPSHOT_FILE" "$LAST_MESSAGE_FILE" "$STREAM_LOG_FILE"
    exit 2
  fi

  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Jarvis completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    cleanup_iteration_temp_files "$ITERATION_PROMPT_FILE" "$PRE_RUN_STORY_SNAPSHOT_FILE" "$LAST_MESSAGE_FILE" "$STREAM_LOG_FILE"
    exit 0
  fi

  if [ -n "$CURRENT_STORY_ID" ] && output_requests_user_input "$OUTPUT"; then
    WAIT_REASON="Agent requested direct user input before proceeding (no unattended fallback applied)."
    mark_story_blocked "$CURRENT_STORY_ID" "$WAIT_REASON" || true

    if clickup_is_ready && [ -n "$CURRENT_TASK_ID" ]; then
      clickup_api_put_status "$CURRENT_TASK_ID" "$CLICKUP_STATUS_WAITING" || true
      clickup_api_post_comment "$CURRENT_TASK_ID" "[$CLICKUP_COMMENT_AUTHOR_LABEL][$CURRENT_STORY_ID][waiting]
Outcome:
- Story paused because the agent requested direct user input.
Reason:
- ${WAIT_REASON}." || true
    fi

    echo ""
    echo "Jarvis marked $CURRENT_STORY_ID as waiting due user-input request and will continue to next iteration."

    cleanup_iteration_temp_files "$ITERATION_PROMPT_FILE" "$PRE_RUN_STORY_SNAPSHOT_FILE" "$LAST_MESSAGE_FILE" "$STREAM_LOG_FILE"
    sleep 2
    continue
  fi

  if echo "$OUTPUT" | grep -q "<promise>BLOCKED</promise>" || { [ -n "$CURRENT_STORY_ID" ] && story_is_blocked "$CURRENT_STORY_ID"; }; then
    RECOVERED=0

    if [ -n "$CURRENT_STORY_ID" ]; then
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
      run_clickup_directives_sync "post-recovery-commit"
      echo ""
      echo "Jarvis recovered blocked git commit for $CURRENT_STORY_ID; continuing."
      cleanup_iteration_temp_files "$ITERATION_PROMPT_FILE" "$PRE_RUN_STORY_SNAPSHOT_FILE" "$LAST_MESSAGE_FILE" "$STREAM_LOG_FILE"
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

    cleanup_iteration_temp_files "$ITERATION_PROMPT_FILE" "$PRE_RUN_STORY_SNAPSHOT_FILE" "$LAST_MESSAGE_FILE" "$STREAM_LOG_FILE"
    sleep 2
    continue
  fi
  
  if clickup_is_ready && [ -n "$CURRENT_STORY_ID" ] && [ -n "$CURRENT_TASK_ID" ]; then
    if story_passes "$CURRENT_STORY_ID"; then
      clickup_api_put_status "$CURRENT_TASK_ID" "$CLICKUP_STATUS_TESTING" || true
    fi
  fi

  echo "Iteration $i complete. Continuing..."
  cleanup_iteration_temp_files "$ITERATION_PROMPT_FILE" "$PRE_RUN_STORY_SNAPSHOT_FILE" "$LAST_MESSAGE_FILE" "$STREAM_LOG_FILE"
  sleep 2
done

echo ""
echo "Jarvis reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
