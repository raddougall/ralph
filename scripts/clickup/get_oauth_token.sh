#!/usr/bin/env bash
set -euo pipefail

# Exchange a ClickUp OAuth authorization code for an access token.
#
# Required env vars:
#   CLICKUP_CLIENT_ID
#   CLICKUP_CLIENT_SECRET
#   CLICKUP_REDIRECT_URI
#   CLICKUP_AUTH_CODE
#
# Usage:
#   CLICKUP_CLIENT_ID=... \
#   CLICKUP_CLIENT_SECRET=... \
#   CLICKUP_REDIRECT_URI=http://localhost:3333/clickup/callback \
#   CLICKUP_AUTH_CODE=... \
#   ./scripts/clickup/get_oauth_token.sh

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    exit 1
  fi
}

require_env CLICKUP_CLIENT_ID
require_env CLICKUP_CLIENT_SECRET
require_env CLICKUP_REDIRECT_URI
require_env CLICKUP_AUTH_CODE

response="$(
  curl -sS -X POST "https://api.clickup.com/api/v2/oauth/token" \
    -H "Content-Type: application/json" \
    -d "{
      \"client_id\": \"${CLICKUP_CLIENT_ID}\",
      \"client_secret\": \"${CLICKUP_CLIENT_SECRET}\",
      \"code\": \"${CLICKUP_AUTH_CODE}\",
      \"redirect_uri\": \"${CLICKUP_REDIRECT_URI}\"
    }"
)"

if [[ "$(jq -r 'has("access_token")' <<<"$response")" != "true" ]]; then
  echo "Failed to exchange auth code for access token." >&2
  echo "$response" | jq .
  exit 1
fi

echo "$response" | jq -r '.access_token'
