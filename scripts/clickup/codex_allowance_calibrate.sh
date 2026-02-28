#!/usr/bin/env bash
set -euo pipefail

# Codex allowance calibration helper for ClickUp custom fields.
#
# Subcommands:
#   record  - append a completed-story sample to calibration CSV
#   recalc  - compute implied capacities from latest N samples (default: 3)
#   apply   - update ClickUp custom fields from estimate CSV + calibrated capacities
#
# Required tools: curl, jq
#
# Shared env vars (for apply):
#   CLICKUP_TOKEN
#   CLICKUP_LIST_ID or CLICKUP_LIST_URL
#
# Optional env vars:
#   CLICKUP_API_BASE (default: https://api.clickup.com/api/v2)
#   CALIBRATION_FILE (default: ./.codex/codex_allowance_samples.csv)
#   ESTIMATES_FILE (default: ./.codex/codex_story_estimates.csv)
#   CALIBRATION_SAMPLE_SIZE (default: 3)
#   CODEX_AUTO_APPLY_ON_RECORD (default: 0; set 1 to auto-apply on record)
#   CODEX_AUTO_APPLY_EVERY (default: 3; auto-apply cadence in sample count)
#   CODEX_WRITE_ESTIMATE_SUMMARY (default: 1; write minutes+% summary into task description)
#   CODEX_WINDOW_NOW_THRESHOLD_PCT (default: 35)
#   CODEX_WINDOW_WEEKLY_THRESHOLD_PCT (default: 35)
#   CODEX_FIELD_5H_NAME (default: Codex 5-hour)
#   CODEX_FIELD_WEEKLY_NAME (default: Codex Weekly)
#   CODEX_FIELD_WINDOW_NAME (default: Codex Window)
#   CODEX_WINDOW_NOW_LABEL (default: 5h-Now)
#   CODEX_WINDOW_WEEKLY_LABEL (default: Weekly)
#   CODEX_WINDOW_LATER_LABEL (default: Later)
#   DRY_RUN=1 (apply mode)

CLICKUP_API_BASE="${CLICKUP_API_BASE:-https://api.clickup.com/api/v2}"
CALIBRATION_FILE="${CALIBRATION_FILE:-./.codex/codex_allowance_samples.csv}"
ESTIMATES_FILE="${ESTIMATES_FILE:-./.codex/codex_story_estimates.csv}"
CALIBRATION_SAMPLE_SIZE="${CALIBRATION_SAMPLE_SIZE:-3}"
CODEX_AUTO_APPLY_ON_RECORD="${CODEX_AUTO_APPLY_ON_RECORD:-0}"
CODEX_AUTO_APPLY_EVERY="${CODEX_AUTO_APPLY_EVERY:-3}"
CODEX_WRITE_ESTIMATE_SUMMARY="${CODEX_WRITE_ESTIMATE_SUMMARY:-1}"
CODEX_WINDOW_NOW_THRESHOLD_PCT="${CODEX_WINDOW_NOW_THRESHOLD_PCT:-35}"
CODEX_WINDOW_WEEKLY_THRESHOLD_PCT="${CODEX_WINDOW_WEEKLY_THRESHOLD_PCT:-35}"
CODEX_FIELD_5H_NAME="${CODEX_FIELD_5H_NAME:-Codex 5-hour}"
CODEX_FIELD_WEEKLY_NAME="${CODEX_FIELD_WEEKLY_NAME:-Codex Weekly}"
CODEX_FIELD_WINDOW_NAME="${CODEX_FIELD_WINDOW_NAME:-Codex Window}"
CODEX_WINDOW_NOW_LABEL="${CODEX_WINDOW_NOW_LABEL:-5h-Now}"
CODEX_WINDOW_WEEKLY_LABEL="${CODEX_WINDOW_WEEKLY_LABEL:-Weekly}"
CODEX_WINDOW_LATER_LABEL="${CODEX_WINDOW_LATER_LABEL:-Later}"
DRY_RUN="${DRY_RUN:-0}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

usage() {
  cat <<USAGE
Usage:
  $0 record --story US-063 --minutes 50 --five-before 82 --five-after 78 [--weekly-before 64 --weekly-after 63] [--auto-apply]
  $0 recalc
  $0 apply

CSV formats:
  Calibration file header:
    completed_at,story_id,minutes_spent,five_before,five_after,weekly_before,weekly_after

  Estimates file header:
    story_id,minutes_p80
USAGE
}

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

auth_header_mode() {
  local token="$1"
  if [[ "$token" == pk_* ]]; then
    echo "Authorization: $token"
  else
    echo "Authorization: Bearer $token"
  fi
}

require_clickup_env() {
  if [[ -z "${CLICKUP_TOKEN:-}" ]]; then
    echo "Missing required env var: CLICKUP_TOKEN" >&2
    exit 1
  fi

  local source_id="${CLICKUP_LIST_ID:-${CLICKUP_LIST_URL:-}}"
  if [[ -z "$source_id" ]]; then
    echo "Set CLICKUP_LIST_ID or CLICKUP_LIST_URL." >&2
    exit 1
  fi

  CLICKUP_LIST_ID="$(extract_list_id "$source_id")"
  if [[ -z "$CLICKUP_LIST_ID" ]]; then
    echo "Could not parse list ID from: $source_id" >&2
    exit 1
  fi

  AUTH_HEADER="$(auth_header_mode "$CLICKUP_TOKEN")"
}

ensure_calibration_file() {
  mkdir -p "$(dirname "$CALIBRATION_FILE")"
  if [[ ! -f "$CALIBRATION_FILE" ]]; then
    echo "completed_at,story_id,minutes_spent,five_before,five_after,weekly_before,weekly_after" > "$CALIBRATION_FILE"
  fi
}

ensure_estimates_file() {
  if [[ ! -f "$ESTIMATES_FILE" ]]; then
    echo "Estimates file not found: $ESTIMATES_FILE" >&2
    exit 1
  fi
}

record_sample() {
  local story_id=""
  local minutes=""
  local five_before=""
  local five_after=""
  local weekly_before=""
  local weekly_after=""
  local auto_apply_override="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --story) story_id="$2"; shift 2 ;;
      --minutes) minutes="$2"; shift 2 ;;
      --five-before) five_before="$2"; shift 2 ;;
      --five-after) five_after="$2"; shift 2 ;;
      --weekly-before) weekly_before="$2"; shift 2 ;;
      --weekly-after) weekly_after="$2"; shift 2 ;;
      --auto-apply) auto_apply_override="1"; shift ;;
      *) echo "Unknown record arg: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$story_id" || -z "$minutes" || -z "$five_before" || -z "$five_after" ]]; then
    echo "record requires: --story, --minutes, --five-before, --five-after" >&2
    exit 1
  fi

  ensure_calibration_file
  printf "%s,%s,%s,%s,%s,%s,%s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$story_id" "$minutes" "$five_before" "$five_after" "$weekly_before" "$weekly_after" >> "$CALIBRATION_FILE"
  echo "Recorded sample for $story_id in $CALIBRATION_FILE"

  local recalc_output
  recalc_output="$(recalc_capacities)"
  echo "$recalc_output"

  local samples_count
  samples_count="$(awk -F'=' '$1=="samples_considered" {print $2}' <<<"$recalc_output")"

  local auto_enabled="${CODEX_AUTO_APPLY_ON_RECORD}"
  if [[ "$auto_apply_override" == "1" ]]; then
    auto_enabled="1"
  fi

  if [[ "$auto_enabled" != "1" ]]; then
    return 0
  fi

  if [[ -z "$samples_count" || "$samples_count" -lt "$CODEX_AUTO_APPLY_EVERY" ]]; then
    echo "Auto-apply skipped: need at least $CODEX_AUTO_APPLY_EVERY samples."
    return 0
  fi

  if (( samples_count % CODEX_AUTO_APPLY_EVERY != 0 )); then
    echo "Auto-apply skipped: waiting for sample multiple of $CODEX_AUTO_APPLY_EVERY (current: $samples_count)."
    return 0
  fi

  if [[ -z "${CLICKUP_TOKEN:-}" || -z "${CLICKUP_LIST_ID:-${CLICKUP_LIST_URL:-}}" ]]; then
    echo "Auto-apply skipped: CLICKUP_TOKEN and CLICKUP_LIST_ID/CLICKUP_LIST_URL are required in environment."
    return 0
  fi

  echo "Auto-apply triggered at sample count $samples_count."
  apply_estimates
}

recalc_capacities() {
  ensure_calibration_file
  awk -F',' -v n="$CALIBRATION_SAMPLE_SIZE" '
    NR==1 { next }
    {
      five_drop=$4-$5;
      weekly_drop=$6-$7;
      idx++;
      mins[idx]=$3+0;
      five[idx]=(five_drop>0?five_drop:0);
      weekly[idx]=(weekly_drop>0?weekly_drop:0);
    }
    END {
      start=idx-n+1;
      if (start<1) start=1;
      msum=0; fsum=0; wsum=0; count=0;
      for (i=start;i<=idx;i++) {
        count++;
        msum += mins[i];
        fsum += five[i];
        wsum += weekly[i];
      }
      five_cap=(fsum>0)?(100*msum/fsum):0;
      weekly_cap=(wsum>0)?(100*msum/wsum):0;
      printf("samples_considered=%d\n", count);
      printf("five_hour_capacity_minutes=%.2f\n", five_cap);
      printf("weekly_capacity_minutes=%.2f\n", weekly_cap);
      printf("recalibrate_now=%s\n", (count>=n?"yes":"no"));
    }
  ' "$CALIBRATION_FILE"
}

api_get() {
  local url="$1"
  curl -sS -X GET "$url" -H "$AUTH_HEADER" -H "Content-Type: application/json"
}

api_post() {
  local url="$1"
  local body="$2"
  curl -sS -X POST "$url" -H "$AUTH_HEADER" -H "Content-Type: application/json" -d "$body"
}

api_put() {
  local url="$1"
  local body="$2"
  curl -sS -X PUT "$url" -H "$AUTH_HEADER" -H "Content-Type: application/json" -d "$body"
}

resolve_field_id() {
  local fields_json="$1"
  local field_name="$2"
  jq -r --arg n "$field_name" '.fields[] | select(.name==$n) | .id' <<<"$fields_json" | head -n1
}

resolve_dropdown_option_id() {
  local fields_json="$1"
  local field_name="$2"
  local option_name="$3"
  jq -r --arg fn "$field_name" --arg on "$option_name" '
    .fields[] | select(.name==$fn) | .type_config.options[] | select(.name==$on) | .id
  ' <<<"$fields_json" | head -n1
}

latest_capacity_value() {
  local key="$1"
  recalc_capacities | awk -F'=' -v k="$key" '$1==k {print $2}'
}

apply_estimates() {
  ensure_calibration_file
  ensure_estimates_file
  require_clickup_env

  local five_cap weekly_cap
  five_cap="$(latest_capacity_value "five_hour_capacity_minutes")"
  weekly_cap="$(latest_capacity_value "weekly_capacity_minutes")"

  if [[ -z "$five_cap" || "$five_cap" == "0.00" ]]; then
    echo "Cannot apply estimates: 5-hour capacity is zero. Record calibration samples first." >&2
    exit 1
  fi
  if [[ -z "$weekly_cap" || "$weekly_cap" == "0.00" ]]; then
    echo "Cannot apply estimates: weekly capacity is zero. Record calibration samples with weekly values first." >&2
    exit 1
  fi

  local fields_json tasks_json
  fields_json="$(api_get "$CLICKUP_API_BASE/list/$CLICKUP_LIST_ID/field")"
  tasks_json="[]"

  local page=0
  while :; do
    local page_response
    page_response="$(api_get "$CLICKUP_API_BASE/list/$CLICKUP_LIST_ID/task?include_closed=true&page=$page")"
    local page_count
    page_count="$(jq -r '.tasks | length' <<<"$page_response" 2>/dev/null || echo "0")"
    if [[ "$page_count" == "0" ]]; then
      break
    fi
    tasks_json="$(jq -s '.[0] + .[1].tasks' <(echo "$tasks_json") <(echo "$page_response"))"
    page=$((page + 1))
  done

  local field_5h field_weekly field_window
  field_5h="$(resolve_field_id "$fields_json" "$CODEX_FIELD_5H_NAME")"
  field_weekly="$(resolve_field_id "$fields_json" "$CODEX_FIELD_WEEKLY_NAME")"
  field_window="$(resolve_field_id "$fields_json" "$CODEX_FIELD_WINDOW_NAME")"

  if [[ -z "$field_5h" || -z "$field_weekly" || -z "$field_window" ]]; then
    echo "Missing one or more required custom fields by name:" >&2
    echo "- $CODEX_FIELD_5H_NAME" >&2
    echo "- $CODEX_FIELD_WEEKLY_NAME" >&2
    echo "- $CODEX_FIELD_WINDOW_NAME" >&2
    exit 1
  fi

  local opt_now opt_weekly opt_later
  opt_now="$(resolve_dropdown_option_id "$fields_json" "$CODEX_FIELD_WINDOW_NAME" "$CODEX_WINDOW_NOW_LABEL")"
  opt_weekly="$(resolve_dropdown_option_id "$fields_json" "$CODEX_FIELD_WINDOW_NAME" "$CODEX_WINDOW_WEEKLY_LABEL")"
  opt_later="$(resolve_dropdown_option_id "$fields_json" "$CODEX_FIELD_WINDOW_NAME" "$CODEX_WINDOW_LATER_LABEL")"

  if [[ -z "$opt_now" || -z "$opt_weekly" || -z "$opt_later" ]]; then
    echo "Missing one or more Codex Window options:" >&2
    echo "- $CODEX_WINDOW_NOW_LABEL" >&2
    echo "- $CODEX_WINDOW_WEEKLY_LABEL" >&2
    echo "- $CODEX_WINDOW_LATER_LABEL" >&2
    exit 1
  fi

  local updated=0
  local skipped=0

  while IFS=',' read -r sid mins; do
    if [[ "$sid" == "story_id" ]]; then
      continue
    fi
    if [[ -z "$sid" || -z "$mins" ]]; then
      continue
    fi

    local task_id
    task_id="$(jq -r --arg s "$sid" '.[] | select(.name|startswith("["+$s+"] ")) | .id' <<<"$tasks_json" | head -n1)"
    if [[ -z "$task_id" ]]; then
      echo "Skip $sid: no ClickUp task found"
      skipped=$((skipped + 1))
      continue
    fi

    local pct_5h pct_weekly window_opt window_label
    pct_5h="$(awk -v m="$mins" -v c="$five_cap" 'BEGIN { printf("%d", (100*m/c)+0.5) }')"
    pct_weekly="$(awk -v m="$mins" -v c="$weekly_cap" 'BEGIN { printf("%d", (100*m/c)+0.5) }')"

    if (( pct_5h <= CODEX_WINDOW_NOW_THRESHOLD_PCT )); then
      window_opt="$opt_now"
      window_label="$CODEX_WINDOW_NOW_LABEL"
    elif (( pct_weekly <= CODEX_WINDOW_WEEKLY_THRESHOLD_PCT )); then
      window_opt="$opt_weekly"
      window_label="$CODEX_WINDOW_WEEKLY_LABEL"
    else
      window_opt="$opt_later"
      window_label="$CODEX_WINDOW_LATER_LABEL"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY_RUN $sid -> mins=$mins 5h=${pct_5h}% weekly=${pct_weekly}% window=$window_label"
      updated=$((updated + 1))
      continue
    fi

    api_post "$CLICKUP_API_BASE/task/$task_id/field/$field_5h" "{\"value\": $pct_5h}" >/dev/null
    api_post "$CLICKUP_API_BASE/task/$task_id/field/$field_weekly" "{\"value\": $pct_weekly}" >/dev/null
    api_post "$CLICKUP_API_BASE/task/$task_id/field/$field_window" "{\"value\": \"$window_opt\"}" >/dev/null

    if [[ "$CODEX_WRITE_ESTIMATE_SUMMARY" == "1" ]]; then
      local current_description base_description summary_block new_description payload
      current_description="$(jq -r --arg tid "$task_id" '.[] | select(.id==$tid) | (.description // "")' <<<"$tasks_json")"
      base_description="$(awk 'BEGIN{skip=0} /<!-- codex-calibration:start -->/{skip=1; next} /<!-- codex-calibration:end -->/{skip=0; next} skip==0{print}' <<<"$current_description")"

      summary_block="<!-- codex-calibration:start -->
Codex Estimate (calibrated):
- P80 minutes: $mins
- Codex 5-hour: ~${pct_5h}%
- Codex Weekly: ~${pct_weekly}%
- Codex Window: $window_label
<!-- codex-calibration:end -->"

      if [[ -n "$(echo "$base_description" | tr -d '[:space:]')" ]]; then
        new_description="$base_description

$summary_block"
      else
        new_description="$summary_block"
      fi

      payload="$(jq -n --arg description "$new_description" '{description: $description}')"
      api_put "$CLICKUP_API_BASE/task/$task_id" "$payload" >/dev/null
    fi

    echo "Updated $sid -> mins=$mins 5h=${pct_5h}% weekly=${pct_weekly}% window=$window_label"
    updated=$((updated + 1))
  done < "$ESTIMATES_FILE"

  echo "Apply complete. Updated: $updated; Skipped: $skipped"
  echo "Calibration used: 5h=${five_cap}min weekly=${weekly_cap}min (based on last ${CALIBRATION_SAMPLE_SIZE} samples)"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    record)
      record_sample "$@"
      ;;
    recalc)
      recalc_capacities
      ;;
    apply)
      apply_estimates
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
