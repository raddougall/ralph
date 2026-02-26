#!/usr/bin/env bash
set -euo pipefail

# Sync a human-readable Jarvis directives overview into a dedicated ClickUp task.
#
# Required env vars:
#   CLICKUP_TOKEN                (OAuth access token or personal token)
#   CLICKUP_LIST_ID              (numeric list ID) OR CLICKUP_LIST_URL
#
# Optional env vars:
#   CLICKUP_API_BASE             (default: https://api.clickup.com/api/v2)
#   CLICKUP_STATUS_TODO          (default: to do)
#   CLICKUP_COMMENT_AUTHOR_LABEL (default: Jarvis/Codex)
#   CLICKUP_DIRECTIVES_TASK_ID   (preferred if known; skips list search)
#   CLICKUP_DIRECTIVES_TASK_NAME (default: [JARVIS-DIRECTIVES] Jarvis Runtime Directives)
#   CLICKUP_DIRECTIVES_SOURCE_FILE (default: ./docs/jarvis-directives-overview.md, fallback to Jarvis master docs file)
#   CLICKUP_DIRECTIVES_DRY_RUN   (set 1 to preview only)
#   CLICKUP_DIRECTIVES_POST_COMMENT (default: 1; post update note comment)
#
# Example:
#   set -a
#   source scripts/clickup/.env.clickup
#   set +a
#   ./scripts/clickup/sync_jarvis_directives_to_clickup.sh

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"
DEFAULT_SOURCE_FILE="$PROJECT_DIR/docs/jarvis-directives-overview.md"
MASTER_SOURCE_FILE="$(cd "$SCRIPT_DIR/../.." && pwd)/docs/jarvis-directives-overview.md"

CLICKUP_API_BASE="${CLICKUP_API_BASE:-https://api.clickup.com/api/v2}"
CLICKUP_STATUS_TODO="${CLICKUP_STATUS_TODO:-to do}"
CLICKUP_COMMENT_AUTHOR_LABEL="${CLICKUP_COMMENT_AUTHOR_LABEL:-Jarvis/Codex}"
CLICKUP_DIRECTIVES_TASK_NAME="${CLICKUP_DIRECTIVES_TASK_NAME:-[JARVIS-DIRECTIVES] Jarvis Runtime Directives}"
CLICKUP_DIRECTIVES_SOURCE_FILE="${CLICKUP_DIRECTIVES_SOURCE_FILE:-$DEFAULT_SOURCE_FILE}"
CLICKUP_DIRECTIVES_DRY_RUN="${CLICKUP_DIRECTIVES_DRY_RUN:-0}"
CLICKUP_DIRECTIVES_POST_COMMENT="${CLICKUP_DIRECTIVES_POST_COMMENT:-1}"

if [[ -z "${CLICKUP_TOKEN:-}" ]]; then
  echo "Missing required env var: CLICKUP_TOKEN" >&2
  exit 1
fi

extract_list_id() {
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

LIST_SOURCE="${CLICKUP_LIST_ID:-${CLICKUP_LIST_URL:-}}"
if [[ -z "$LIST_SOURCE" ]]; then
  echo "Set CLICKUP_LIST_ID or CLICKUP_LIST_URL." >&2
  exit 1
fi

CLICKUP_LIST_ID="$(extract_list_id "$LIST_SOURCE")"
if [[ -z "$CLICKUP_LIST_ID" ]]; then
  echo "Could not parse list ID from: $LIST_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$CLICKUP_DIRECTIVES_SOURCE_FILE" && -f "$MASTER_SOURCE_FILE" ]]; then
  CLICKUP_DIRECTIVES_SOURCE_FILE="$MASTER_SOURCE_FILE"
fi

if [[ ! -f "$CLICKUP_DIRECTIVES_SOURCE_FILE" ]]; then
  echo "Directives source file not found: $CLICKUP_DIRECTIVES_SOURCE_FILE" >&2
  exit 1
fi

auth_header_mode() {
  local token="$1"
  if [[ "$token" == pk_* ]]; then
    echo "Authorization: $token"
  else
    echo "Authorization: Bearer $token"
  fi
}

AUTH_HEADER="$(auth_header_mode "$CLICKUP_TOKEN")"

api_get() {
  local url="$1"
  curl -sS -X GET "$url" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json"
}

api_post() {
  local url="$1"
  local body="$2"
  curl -sS -X POST "$url" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$body"
}

api_put() {
  local url="$1"
  local body="$2"
  curl -sS -X PUT "$url" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$body"
}

list_response="$(api_get "$CLICKUP_API_BASE/list/$CLICKUP_LIST_ID")"
if [[ "$(jq -r 'has("id")' <<<"$list_response")" != "true" ]]; then
  echo "Failed to load ClickUp list metadata. Response:" >&2
  echo "$list_response" | jq .
  exit 1
fi

todo_status="$(
  jq -r --arg preferred_todo "$CLICKUP_STATUS_TODO" '
    ([
      .statuses[]
      | select((.status | ascii_downcase) == ($preferred_todo | ascii_downcase))
    ][0].status)
    // ([
      .statuses[]
      | select(
          ((.type | ascii_downcase) == "open" or (.type | ascii_downcase) == "custom")
          and ((.status | ascii_downcase) != "backlog")
        )
    ][0].status)
    // (.statuses[0].status)
    // empty
  ' <<<"$list_response"
)"

if [[ -z "$todo_status" ]]; then
  echo "Could not determine a writable open status from list metadata." >&2
  exit 1
fi

source_file_label="${CLICKUP_DIRECTIVES_SOURCE_FILE#$PROJECT_DIR/}"
if [[ "$source_file_label" = "$CLICKUP_DIRECTIVES_SOURCE_FILE" ]]; then
  source_file_label="$CLICKUP_DIRECTIVES_SOURCE_FILE"
fi

directives_content="$(cat "$CLICKUP_DIRECTIVES_SOURCE_FILE")"
description_header=$'# Jarvis Runtime Directives\n\n'
description_meta="Source: ${source_file_label}\nLast synced: $(date -u '+%Y-%m-%d %H:%M:%S UTC')\n\n"
description="${description_header}${description_meta}${directives_content}"

if [[ "${CLICKUP_DIRECTIVES_DRY_RUN}" == "1" ]]; then
  echo "DRY RUN: would sync directives into list $CLICKUP_LIST_ID"
  echo "Task name: $CLICKUP_DIRECTIVES_TASK_NAME"
  echo "Source: $CLICKUP_DIRECTIVES_SOURCE_FILE"
  exit 0
fi

task_id="${CLICKUP_DIRECTIVES_TASK_ID:-}"
task_name="$CLICKUP_DIRECTIVES_TASK_NAME"
task_exists=0
previous_description=""

if [[ -n "$task_id" ]]; then
  task_response="$(api_get "$CLICKUP_API_BASE/task/$task_id")"
  if [[ "$(jq -r 'has("id")' <<<"$task_response")" != "true" ]]; then
    echo "Could not load CLICKUP_DIRECTIVES_TASK_ID=$task_id. Response:" >&2
    echo "$task_response" | jq .
    exit 1
  fi
  task_exists=1
  task_name="$(jq -r '.name // empty' <<<"$task_response")"
  previous_description="$(jq -r '.description // ""' <<<"$task_response")"
else
  tasks_file="$(mktemp)"
  trap 'rm -f "${tasks_file:-}"' EXIT
  echo "[]" >"$tasks_file"

  page=0
  while :; do
    page_response="$(api_get "$CLICKUP_API_BASE/list/$CLICKUP_LIST_ID/task?include_closed=true&page=$page")"
    page_count="$(jq -r '.tasks | length' <<<"$page_response" 2>/dev/null || echo "0")"
    if [[ "$page_count" == "0" ]]; then
      break
    fi
    jq -s '.[0] + .[1].tasks' "$tasks_file" <(echo "$page_response") >"${tasks_file}.next"
    mv "${tasks_file}.next" "$tasks_file"
    page=$((page + 1))
  done

  existing_task="$(jq -c --arg name "$task_name" 'map(select(.name == $name)) | .[0]' "$tasks_file")"
  if [[ "$existing_task" != "null" ]]; then
    task_exists=1
    task_id="$(jq -r '.id' <<<"$existing_task")"
    previous_description="$(jq -r '.description // ""' <<<"$existing_task")"
  fi
fi

if [[ "$task_exists" == "1" ]]; then
  update_body="$(jq -n \
    --arg description "$description" \
    '{description: $description}')"
  update_response="$(api_put "$CLICKUP_API_BASE/task/$task_id" "$update_body")"
  if [[ "$(jq -r 'has("id")' <<<"$update_response")" != "true" ]]; then
    echo "Failed to update directives task $task_id. Response:" >&2
    echo "$update_response" | jq .
    exit 1
  fi
  action="updated"
else
  create_body="$(jq -n \
    --arg name "$task_name" \
    --arg status "$todo_status" \
    --arg description "$description" \
    '{name: $name, status: $status, description: $description}')"
  create_response="$(api_post "$CLICKUP_API_BASE/list/$CLICKUP_LIST_ID/task" "$create_body")"
  if [[ "$(jq -r 'has("id")' <<<"$create_response")" != "true" ]]; then
    echo "Failed to create directives task. Response:" >&2
    echo "$create_response" | jq .
    exit 1
  fi
  task_id="$(jq -r '.id' <<<"$create_response")"
  action="created"
fi

if [[ "$CLICKUP_DIRECTIVES_POST_COMMENT" == "1" ]]; then
  if [[ "$previous_description" != "$description" || "$action" == "created" ]]; then
    comment_text="[$CLICKUP_COMMENT_AUTHOR_LABEL][directives]
Outcome:
- Jarvis directives overview ${action} from source ${source_file_label}.
Task:
- ${task_name} (${task_id})."
    comment_body="$(jq -n --arg comment_text "$comment_text" '{comment_text:$comment_text, notify_all:false}')"
    api_post "$CLICKUP_API_BASE/task/$task_id/comment" "$comment_body" >/dev/null
  fi
fi

echo "Directives task ${action}: ${task_name} (${task_id})"
echo "Source synced: $CLICKUP_DIRECTIVES_SOURCE_FILE"
