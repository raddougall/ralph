#!/usr/bin/env bash
set -euo pipefail

# Sync prd.json stories into a ClickUp list.
#
# Required env vars:
#   CLICKUP_TOKEN        (OAuth access token or personal token)
#   CLICKUP_LIST_ID      (numeric list ID) OR CLICKUP_LIST_URL
#
# Optional env vars:
#   CLICKUP_API_BASE     (default: https://api.clickup.com/api/v2)
#   PRD_FILE             (default: ./prd.json)
#   DRY_RUN              (set to 1 to print actions only)
#   CLICKUP_STATUS_TODO  (default: to do)
#   CLICKUP_STATUS_DONE (default: done)
#   CLICKUP_STATUS_TESTING (default: testing)
#   CLICKUP_STATUS_DEPLOYED (default: deployed)
#   CLICKUP_STATUS_PLANNING (default: planning)
#   JARVIS_CLICKUP_AUTO_DEPLOY_ON_MAIN (default: 0)
#   JARVIS_MAIN_BRANCH (default: main)
#
# Example:
#   CLICKUP_TOKEN=... \
#   CLICKUP_LIST_URL="https://app.clickup.com/123/v/li/456" \
#   ./scripts/clickup/sync_prd_to_clickup.sh

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

CLICKUP_API_BASE="${CLICKUP_API_BASE:-https://api.clickup.com/api/v2}"
PRD_FILE="${PRD_FILE:-./prd.json}"
DRY_RUN="${DRY_RUN:-0}"
CLICKUP_STATUS_TODO="${CLICKUP_STATUS_TODO:-to do}"
CLICKUP_STATUS_DONE="${CLICKUP_STATUS_DONE:-done}"
CLICKUP_STATUS_TESTING="${CLICKUP_STATUS_TESTING:-testing}"
CLICKUP_STATUS_DEPLOYED="${CLICKUP_STATUS_DEPLOYED:-deployed}"
CLICKUP_STATUS_PLANNING="${CLICKUP_STATUS_PLANNING:-planning}"
CLICKUP_MAIN_BRANCH="${JARVIS_MAIN_BRANCH:-${RALPH_MAIN_BRANCH:-main}}"
CLICKUP_AUTO_DEPLOY_ON_MAIN="${JARVIS_CLICKUP_AUTO_DEPLOY_ON_MAIN:-${RALPH_CLICKUP_AUTO_DEPLOY_ON_MAIN:-0}}"

if [[ -z "${CLICKUP_TOKEN:-}" ]]; then
  echo "Missing required env var: CLICKUP_TOKEN" >&2
  exit 1
fi

if [[ ! -f "$PRD_FILE" ]]; then
  echo "PRD file not found: $PRD_FILE" >&2
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
    // ([
      .statuses[]
      | select((.type | ascii_downcase) == "open" or (.type | ascii_downcase) == "custom")
    ][0].status)
    // (.statuses[0].status)
    // empty
  ' <<<"$list_response"
)"

done_status="$(
  jq -r '
    ([
      .statuses[]
      | select((.type | ascii_downcase) == "done" or (.type | ascii_downcase) == "closed")
    ][0].status)
    // (.statuses[-1].status)
    // empty
  ' <<<"$list_response"
)"

if [[ -z "$todo_status" || -z "$done_status" ]]; then
  echo "Could not determine todo/done statuses from list metadata." >&2
  echo "$list_response" | jq '.statuses'
  exit 1
fi

resolve_clickup_status() {
  local requested_status="$1"
  if [[ -z "$requested_status" ]]; then
    echo ""
    return
  fi

  jq -r --arg requested_status "$requested_status" '
    ([
      .statuses[]
      | select((.status | ascii_downcase) == ($requested_status | ascii_downcase))
    ][0].status)
    // empty
  ' <<<"$list_response"
}

testing_status="$(resolve_clickup_status "$CLICKUP_STATUS_TESTING")"
if [[ -z "$testing_status" ]]; then
  testing_status="$CLICKUP_STATUS_TESTING"
fi

done_status_preferred="$(resolve_clickup_status "$CLICKUP_STATUS_DONE")"
if [[ -z "$done_status_preferred" ]]; then
  done_status_preferred="$CLICKUP_STATUS_DONE"
fi

deployed_status="$(resolve_clickup_status "$CLICKUP_STATUS_DEPLOYED")"
if [[ -z "$deployed_status" ]]; then
  deployed_status="$CLICKUP_STATUS_DEPLOYED"
fi

planning_status="$(resolve_clickup_status "$CLICKUP_STATUS_PLANNING")"
if [[ -z "$planning_status" ]]; then
  planning_status="$CLICKUP_STATUS_PLANNING"
fi

current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

echo "Using list ID: $CLICKUP_LIST_ID"
echo "Status mapping: todo='$todo_status' planning='$planning_status' done='$done_status_preferred' testing='$testing_status' deployed='$deployed_status' (legacy done='$done_status')"

tasks_file="$(mktemp)"
trap 'rm -f "$tasks_file"' EXIT
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

priority_to_clickup() {
  local p="$1"
  if [[ "$p" -le 5 ]]; then
    echo "1"   # urgent
  elif [[ "$p" -le 15 ]]; then
    echo "2"   # high
  elif [[ "$p" -le 30 ]]; then
    echo "3"   # normal
  else
    echo "4"   # low
  fi
}

build_description() {
  local story_json="$1"
  jq -r '
    "Story ID: " + .id + "\n\n"
    + "Description:\n" + .description + "\n\n"
    + "Acceptance Criteria:\n"
    + (.acceptanceCriteria | map("- " + .) | join("\n"))
    + (if (.notes // "") != "" then "\n\nNotes:\n" + .notes else "" end)
  ' <<<"$story_json"
}

created=0
updated=0
unchanged=0

while IFS= read -r story; do
  story_id="$(jq -r '.id' <<<"$story")"
  title="$(jq -r '.title' <<<"$story")"
  passes="$(jq -r '.passes' <<<"$story")"
  story_clickup_status="$(jq -r '.clickupStatus // empty' <<<"$story")"
  priority="$(jq -r '.priority' <<<"$story")"

  task_name="[$story_id] $title"
  if [[ -n "$story_clickup_status" ]]; then
    status="$(resolve_clickup_status "$story_clickup_status")"
    if [[ -z "$status" ]]; then
      status="$story_clickup_status"
    fi
  else
    status="$todo_status"
    if [[ "$passes" == "true" ]]; then
      if [[ -n "$current_branch" && "$current_branch" == "$CLICKUP_MAIN_BRANCH" ]]; then
        status="$done_status_preferred"
        if [[ "$CLICKUP_AUTO_DEPLOY_ON_MAIN" == "1" ]]; then
          status="$deployed_status"
        fi
      else
        status="$testing_status"
      fi
    fi
  fi
  clickup_priority="$(priority_to_clickup "$priority")"
  description="$(build_description "$story")"

  existing_task="$(jq -c --arg sid "$story_id" '
    map(select(.name | startswith("[" + $sid + "] ")))
    | .[0]
  ' "$tasks_file")"

  if [[ "$existing_task" == "null" ]]; then
    body="$(jq -n \
      --arg name "$task_name" \
      --arg description "$description" \
      --arg status "$status" \
      --arg priority "$clickup_priority" \
      '{
        name: $name,
        description: $description,
        status: $status,
        priority: $priority
      }')"

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "CREATE $task_name -> status=$status"
    else
      create_response="$(api_post "$CLICKUP_API_BASE/list/$CLICKUP_LIST_ID/task" "$body")"
      if [[ "$(jq -r 'has("id")' <<<"$create_response")" != "true" ]]; then
        echo "Failed creating task for $story_id" >&2
        echo "$create_response" | jq .
        exit 1
      fi
      echo "Created $task_name"
    fi
    created=$((created + 1))
    continue
  fi

  task_id="$(jq -r '.id' <<<"$existing_task")"
  current_status="$(jq -r '.status.status // ""' <<<"$existing_task")"
  current_priority="$(jq -r '.priority.priority // ""' <<<"$existing_task")"
  current_description="$(jq -r '.description // ""' <<<"$existing_task")"
  current_name="$(jq -r '.name' <<<"$existing_task")"

  if [[ -z "$story_clickup_status" && "$passes" != "true" ]]; then
    if [[ "$(echo "$current_status" | tr '[:upper:]' '[:lower:]')" == "$(echo "$planning_status" | tr '[:upper:]' '[:lower:]')" ]]; then
      status="$current_status"
    fi
  fi

  if [[ "$current_status" == "$status" && "$current_priority" == "$clickup_priority" && "$current_name" == "$task_name" && "$current_description" == "$description" ]]; then
    unchanged=$((unchanged + 1))
    continue
  fi

  body="$(jq -n \
    --arg name "$task_name" \
    --arg description "$description" \
    --arg status "$status" \
    --arg priority "$clickup_priority" \
    '{
      name: $name,
      description: $description,
      status: $status,
      priority: $priority
    }')"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "UPDATE $task_name (task_id=$task_id) -> status=$status"
  else
    update_response="$(api_put "$CLICKUP_API_BASE/task/$task_id" "$body")"
    if [[ "$(jq -r 'has("id")' <<<"$update_response")" != "true" ]]; then
      echo "Failed updating task for $story_id (task_id=$task_id)" >&2
      echo "$update_response" | jq .
      exit 1
    fi
    echo "Updated $task_name"
  fi
  updated=$((updated + 1))
done < <(jq -c '.userStories[]' "$PRD_FILE")

echo ""
echo "Sync complete."
echo "Created: $created"
echo "Updated: $updated"
echo "Unchanged: $unchanged"
