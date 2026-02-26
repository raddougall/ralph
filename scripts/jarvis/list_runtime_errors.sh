#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JARVIS_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
FEEDBACK_FILE="${JARVIS_ERROR_FEEDBACK_FILE:-$JARVIS_HOME/runtime-feedback/error-events.jsonl}"
LIMIT="${1:-50}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

if [[ ! -f "$FEEDBACK_FILE" ]]; then
  echo "No feedback file found at: $FEEDBACK_FILE"
  exit 0
fi

tail -n "$LIMIT" "$FEEDBACK_FILE" \
  | jq -s '
      map(select(type == "object"))
      | sort_by(.timestamp)
      | reverse
      | map({
          timestamp,
          project: .project.name,
          branch: .project.branch,
          phase,
          severity,
          reason,
          story_id: .story.id,
          story_title: .story.title,
          iteration,
          details
        })
    '
