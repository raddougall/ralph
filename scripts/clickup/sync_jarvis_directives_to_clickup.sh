#!/usr/bin/env bash
set -euo pipefail

# Sync a human-readable Jarvis directives overview into a ClickUp Doc page.
#
# Required env vars:
#   CLICKUP_TOKEN
#
# Required doc target (choose one):
#   CLICKUP_DIRECTIVES_DOC_URL         (recommended, e.g. https://app.clickup.com/<workspace>/v/dc/<doc_id>)
#   or CLICKUP_WORKSPACE_ID + CLICKUP_DIRECTIVES_DOC_ID
#
# Optional env vars:
#   CLICKUP_API_BASE                   (default: https://api.clickup.com/api/v2)
#   CLICKUP_API_V3_BASE                (default: https://api.clickup.com/api/v3)
#   CLICKUP_DIRECTIVES_PAGE_ID         (if omitted, first page from pageListing is used)
#   CLICKUP_DIRECTIVES_SOURCE_FILE     (default: ./docs/jarvis-directives-overview.md, fallback to Jarvis master docs file)
#   CLICKUP_DIRECTIVES_DRY_RUN         (set 1 to preview only)

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

if [[ -z "${CLICKUP_TOKEN:-}" ]]; then
  echo "Missing required env var: CLICKUP_TOKEN" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"
DEFAULT_SOURCE_FILE="$PROJECT_DIR/docs/jarvis-directives-overview.md"
MASTER_SOURCE_FILE="$(cd "$SCRIPT_DIR/../.." && pwd)/docs/jarvis-directives-overview.md"

CLICKUP_API_BASE="${CLICKUP_API_BASE:-https://api.clickup.com/api/v2}"
CLICKUP_API_V3_BASE="${CLICKUP_API_V3_BASE:-https://api.clickup.com/api/v3}"
CLICKUP_DIRECTIVES_SOURCE_FILE="${CLICKUP_DIRECTIVES_SOURCE_FILE:-$DEFAULT_SOURCE_FILE}"
CLICKUP_DIRECTIVES_DRY_RUN="${CLICKUP_DIRECTIVES_DRY_RUN:-0}"
CLICKUP_DIRECTIVES_DOC_URL="${CLICKUP_DIRECTIVES_DOC_URL:-}"
CLICKUP_WORKSPACE_ID="${CLICKUP_WORKSPACE_ID:-}"
CLICKUP_DIRECTIVES_DOC_ID="${CLICKUP_DIRECTIVES_DOC_ID:-}"
CLICKUP_DIRECTIVES_PAGE_ID="${CLICKUP_DIRECTIVES_PAGE_ID:-}"

if [[ ! -f "$CLICKUP_DIRECTIVES_SOURCE_FILE" && -f "$MASTER_SOURCE_FILE" ]]; then
  CLICKUP_DIRECTIVES_SOURCE_FILE="$MASTER_SOURCE_FILE"
fi

if [[ ! -f "$CLICKUP_DIRECTIVES_SOURCE_FILE" ]]; then
  echo "Directives source file not found: $CLICKUP_DIRECTIVES_SOURCE_FILE" >&2
  exit 1
fi

if [[ -n "$CLICKUP_DIRECTIVES_DOC_URL" ]]; then
  if [[ -z "$CLICKUP_WORKSPACE_ID" && "$CLICKUP_DIRECTIVES_DOC_URL" =~ app\.clickup\.com/([0-9]+)/v/dc/([^/?#]+) ]]; then
    CLICKUP_WORKSPACE_ID="${BASH_REMATCH[1]}"
    CLICKUP_DIRECTIVES_DOC_ID="${BASH_REMATCH[2]}"
  fi
fi

if [[ -z "$CLICKUP_WORKSPACE_ID" || -z "$CLICKUP_DIRECTIVES_DOC_ID" ]]; then
  echo "Set CLICKUP_DIRECTIVES_DOC_URL, or both CLICKUP_WORKSPACE_ID and CLICKUP_DIRECTIVES_DOC_ID." >&2
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

api_v3_get() {
  local path="$1"
  curl -sS -X GET "${CLICKUP_API_V3_BASE}${path}" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json"
}

api_v3_put() {
  local path="$1"
  local body="$2"
  curl -sS -X PUT "${CLICKUP_API_V3_BASE}${path}" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$body"
}

doc_metadata="$(api_v3_get "/workspaces/$CLICKUP_WORKSPACE_ID/docs/$CLICKUP_DIRECTIVES_DOC_ID")"
if [[ "$(jq -r 'has("id")' <<<"$doc_metadata" 2>/dev/null || echo "false")" != "true" ]]; then
  echo "Failed to load directives doc metadata for doc id $CLICKUP_DIRECTIVES_DOC_ID. Response:" >&2
  echo "$doc_metadata" >&2
  exit 1
fi

if [[ -z "$CLICKUP_DIRECTIVES_PAGE_ID" ]]; then
  page_listing="$(api_v3_get "/workspaces/$CLICKUP_WORKSPACE_ID/docs/$CLICKUP_DIRECTIVES_DOC_ID/pageListing")"
  CLICKUP_DIRECTIVES_PAGE_ID="$(jq -r '.[0].id // empty' <<<"$page_listing" 2>/dev/null || true)"
  if [[ -z "$CLICKUP_DIRECTIVES_PAGE_ID" ]]; then
    echo "Failed to resolve directives doc page id from pageListing. Response:" >&2
    echo "$page_listing" >&2
    exit 1
  fi
fi

source_file_label="${CLICKUP_DIRECTIVES_SOURCE_FILE#$PROJECT_DIR/}"
if [[ "$source_file_label" = "$CLICKUP_DIRECTIVES_SOURCE_FILE" ]]; then
  source_file_label="$CLICKUP_DIRECTIVES_SOURCE_FILE"
fi

directives_content="$(cat "$CLICKUP_DIRECTIVES_SOURCE_FILE")"
doc_body_content=$'# Jarvis Runtime Directives\n\n'
doc_body_content+=$"Source: ${source_file_label}"$'\n'
doc_body_content+=$"Last synced: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"$'\n\n'
doc_body_content+="$directives_content"

if [[ "$CLICKUP_DIRECTIVES_DRY_RUN" == "1" ]]; then
  echo "DRY RUN: would sync directives to doc $CLICKUP_DIRECTIVES_DOC_ID page $CLICKUP_DIRECTIVES_PAGE_ID"
  echo "Source: $CLICKUP_DIRECTIVES_SOURCE_FILE"
  exit 0
fi

update_body="$(jq -n --arg content "$doc_body_content" '{content: $content}')"
api_v3_put "/workspaces/$CLICKUP_WORKSPACE_ID/docs/$CLICKUP_DIRECTIVES_DOC_ID/pages/$CLICKUP_DIRECTIVES_PAGE_ID" "$update_body" >/dev/null

echo "Directives doc synced: doc=$CLICKUP_DIRECTIVES_DOC_ID page=$CLICKUP_DIRECTIVES_PAGE_ID workspace=$CLICKUP_WORKSPACE_ID"
echo "Source synced: $CLICKUP_DIRECTIVES_SOURCE_FILE"
