#!/usr/bin/env bash
set -euo pipefail

# Sync ClickUp [US-xxx] tasks into local prd.json.
#
# Required env vars:
#   CLICKUP_TOKEN        (OAuth access token or personal token)
#   CLICKUP_LIST_ID      (numeric list ID) OR CLICKUP_LIST_URL
#
# Optional env vars:
#   CLICKUP_API_BASE         (default: https://api.clickup.com/api/v2)
#   PRD_FILE                 (default: ./prd.json)
#   PROGRESS_FILE            (default: ./progress.txt)
#   DRY_RUN                  (set to 1 to preview without writing)
#   CLICKUP_PRUNE_MISSING    (set to 1 to remove local stories missing in ClickUp; default: 0)
#   CLICKUP_SYNC_APPEND_PROGRESS (set to 1 to append sync note to progress log; default: 1)
#   CLICKUP_PROJECT_NAME     (optional override for prd.json project)
#   CLICKUP_BRANCH_NAME      (optional override for prd.json branchName)
#   CLICKUP_PROJECT_DESCRIPTION (optional override for prd.json description)
#
# Example:
#   CLICKUP_TOKEN=... \
#   CLICKUP_LIST_URL="https://app.clickup.com/123/v/li/456" \
#   ./scripts/clickup/sync_clickup_to_prd.sh

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
PROGRESS_FILE="${PROGRESS_FILE:-./progress.txt}"
DRY_RUN="${DRY_RUN:-0}"
CLICKUP_PRUNE_MISSING="${CLICKUP_PRUNE_MISSING:-0}"
CLICKUP_SYNC_APPEND_PROGRESS="${CLICKUP_SYNC_APPEND_PROGRESS:-1}"
CLICKUP_STATUS_TESTING="${CLICKUP_STATUS_TESTING:-testing}"

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

list_response="$(api_get "$CLICKUP_API_BASE/list/$CLICKUP_LIST_ID")"
if [[ "$(jq -r 'has("id")' <<<"$list_response")" != "true" ]]; then
  echo "Failed to load ClickUp list metadata. Response:" >&2
  echo "$list_response" | jq .
  exit 1
fi

list_name="$(jq -r '.name // "ClickUp List"' <<<"$list_response")"

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

stories_from_clickup="$(
  jq -c --arg testing_status "$(echo "$CLICKUP_STATUS_TESTING" | tr '[:upper:]' '[:lower:]')" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def after($token): if contains($token) then (split($token)[1]) else "" end;
    def until_any($tokens):
      reduce $tokens[] as $tok (.;
        if contains($tok) then split($tok)[0] else . end
      );
    def parse_description($raw):
      if ($raw | contains("\nDescription:\n")) then
        ($raw
          | after("\nDescription:\n")
          | until_any(["\n\nAcceptance Criteria:\n", "\n\nNotes:\n"])
          | trim)
      else
        ($raw | trim)
      end;
    def parse_acceptance($raw):
      if ($raw | contains("\nAcceptance Criteria:\n")) then
        ($raw
          | after("\nAcceptance Criteria:\n")
          | until_any(["\n\nNotes:\n"])
          | split("\n")
          | map(trim)
          | map(select(startswith("- ")))
          | map(ltrimstr("- ") | trim)
          | map(select(length > 0)))
      else
        []
      end;
    def parse_notes($raw):
      if ($raw | contains("\n\nNotes:\n")) then
        ($raw | after("\n\nNotes:\n") | trim)
      else
        ""
      end;
    def priority_to_local($p):
      if $p == "1" then 5
      elif $p == "2" then 10
      elif $p == "3" then 20
      elif $p == "4" then 40
      else null
      end;

    [
      .[]
      | select(.name | test("^\\[US-[0-9]+\\] "))
      | . as $task
      | ($task.name | capture("^\\[(?<id>US-[0-9]+)\\]\\s*(?<title>.*)$")) as $name
      | ($task.description // "") as $raw
      | {
          id: $name.id,
          order: (($name.id | capture("^US-(?<n>[0-9]+)$").n) | tonumber),
          title: ($name.title | trim),
          description: parse_description($raw),
          acceptanceCriteria: parse_acceptance($raw),
          notes: parse_notes($raw),
          priority: priority_to_local($task.priority.priority // ""),
          passes: (
            (($task.status.type // "") | ascii_downcase) as $type
            | (($task.status.status // "") | ascii_downcase) as $status
            | ($type == "done" or $type == "closed" or $status == $testing_status)
          )
        }
    ]
    | sort_by(.order)
  ' "$tasks_file"
)"

story_count="$(jq -r 'length' <<<"$stories_from_clickup")"
all_task_count="$(jq -r 'length' "$tasks_file")"
skipped_count=$((all_task_count - story_count))

if [[ "$story_count" -eq 0 ]]; then
  echo "No [US-xxx] tasks found in ClickUp list $CLICKUP_LIST_ID. Nothing to sync." >&2
  exit 1
fi

if [[ -f "$PRD_FILE" ]]; then
  if ! jq -e . "$PRD_FILE" >/dev/null 2>&1; then
    echo "Existing PRD file is not valid JSON: $PRD_FILE" >&2
    exit 1
  fi
  existing_prd="$(cat "$PRD_FILE")"
else
  existing_prd='{}'
fi

if [[ "$CLICKUP_PRUNE_MISSING" == "1" ]]; then
  prune_missing_json=true
else
  prune_missing_json=false
fi

preserved_count="$(
  jq -n \
    --argjson existing "$existing_prd" \
    --argjson stories "$stories_from_clickup" '
      ($existing.userStories // []) as $existingStories
      | ($stories | map(.id)) as $syncedIds
      | ($existingStories | map(select((.id as $id | ($syncedIds | index($id))) == null)) | length)
    '
)"

new_prd="$(
  jq -n \
    --argjson existing "$existing_prd" \
    --argjson stories "$stories_from_clickup" \
    --arg project_override "${CLICKUP_PROJECT_NAME:-}" \
    --arg branch_override "${CLICKUP_BRANCH_NAME:-}" \
    --arg desc_override "${CLICKUP_PROJECT_DESCRIPTION:-}" \
    --arg list_name "$list_name" \
    --arg list_id "$CLICKUP_LIST_ID" \
    --argjson prune_missing "$prune_missing_json" '
      def order_key($id): (try ($id | capture("^US-(?<n>[0-9]+)$").n | tonumber) catch 999999);

      ($existing.userStories // []) as $existingStories
      | ($stories | map(.id)) as $syncedIds
      | ($stories
          | map(
              . as $story
              | ($existingStories | map(select(.id == $story.id)) | .[0]) as $prev
              | {
                  id: $story.id,
                  title: (if ($story.title | length) > 0 then $story.title else ($prev.title // $story.id) end),
                  description: (
                    if ($story.description | length) > 0 then $story.description
                    else ($prev.description // "See ClickUp task details.")
                    end
                  ),
                  acceptanceCriteria: (
                    if ($story.acceptanceCriteria | length) > 0 then $story.acceptanceCriteria
                    else ($prev.acceptanceCriteria // [])
                    end
                  ),
                  priority: ($prev.priority // $story.priority // (order_key($story.id) * 10)),
                  passes: $story.passes,
                  notes: (if ($story.notes | length) > 0 then $story.notes else ($prev.notes // "") end)
                }
            )
        ) as $syncedStories
      | ($existingStories | map(select((.id as $id | ($syncedIds | index($id))) == null))) as $missingStories
      | {
          project: (
            if ($project_override | length) > 0 then $project_override
            elif (($existing.project // "") | length) > 0 then $existing.project
            else ($list_name + " (ClickUp)")
            end
          ),
          branchName: (
            if ($branch_override | length) > 0 then $branch_override
            elif (($existing.branchName // "") | length) > 0 then $existing.branchName
            else "jarvis/clickup-import"
            end
          ),
          description: (
            if ($desc_override | length) > 0 then $desc_override
            elif (($existing.description // "") | length) > 0 then $existing.description
            else ("Synced from ClickUp list " + $list_id)
            end
          ),
          userStories: (
            ($syncedStories + (if $prune_missing then [] else $missingStories end))
            | sort_by(order_key(.id))
          )
        }
    '
)"

done_count="$(jq -r '[.[] | select(.passes == true)] | length' <<<"$stories_from_clickup")"
open_count=$((story_count - done_count))

echo "Using list ID: $CLICKUP_LIST_ID ($list_name)"
echo "Story tasks found: $story_count (done: $done_count, open: $open_count)"
if [[ "$skipped_count" -gt 0 ]]; then
  echo "Skipped non-story tasks: $skipped_count"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN=1, would write merged PRD to $PRD_FILE"
  echo "$new_prd" | jq .
  exit 0
fi

tmp_prd="$(mktemp)"
echo "$new_prd" | jq . >"$tmp_prd"

was_changed=1
if [[ -f "$PRD_FILE" ]]; then
  if diff -q "$tmp_prd" <(jq . "$PRD_FILE") >/dev/null 2>&1; then
    was_changed=0
  fi
fi

mv "$tmp_prd" "$PRD_FILE"
echo "Synced local PRD: $PRD_FILE"

if [[ "$CLICKUP_SYNC_APPEND_PROGRESS" == "1" ]]; then
  if [[ ! -f "$PROGRESS_FILE" ]]; then
    {
      echo "# Jarvis Progress Log"
      echo "Started: $(date)"
      echo "---"
    } >"$PROGRESS_FILE"
  fi

  {
    echo "## [$(date '+%Y-%m-%d %H:%M:%S %Z')] - CLICKUP-SYNC"
    echo "- Synced ClickUp list $CLICKUP_LIST_ID ($list_name) into $PRD_FILE"
    echo "- Story tasks imported: $story_count (done: $done_count, open: $open_count)"
    if [[ "$skipped_count" -gt 0 ]]; then
      echo "- Skipped non-story tasks (no [US-xxx] prefix): $skipped_count"
    fi
    if [[ "$CLICKUP_PRUNE_MISSING" == "1" ]]; then
      echo "- Local-only stories removed because CLICKUP_PRUNE_MISSING=1"
    else
      echo "- Local-only stories preserved: $preserved_count (set CLICKUP_PRUNE_MISSING=1 to remove)"
    fi
    if [[ "$was_changed" -eq 1 ]]; then
      echo "- Result: prd.json updated from ClickUp"
    else
      echo "- Result: no changes detected in prd.json"
    fi
    echo "---"
  } >>"$PROGRESS_FILE"
fi

