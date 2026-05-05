#!/usr/bin/env bash
# collect-investigations.sh — assemble subagent JSON outputs into a verdict
# queue the main agent feeds into batch-verify-profile.sh per profile.
#
# Usage:
#   collect-investigations.sh --run-id <id> [--require-all]
#
# Reads:  $OPS_RUN_DIR/investigations/<run_id>/*.json (one per profile)
#         + the run's profile_group_fetched events (for the expected set)
# Writes: stdout — JSON array, one entry per profile:
#   {profile_id, cr_ids, verdict, reason, evidence_excerpts, browser_load_urls,
#    credited_name, track_title, role, status: "ready" | "missing"}
# Exit codes:
#   0 = at least one investigation collected
#   2 = invalid args / env
#   4 = --require-all set and ≥1 expected investigations missing

set -euo pipefail

RUN_ID=""
REQUIRE_ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --require-all) REQUIRE_ALL=1; shift ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$RUN_ID"          ]] || { echo "ERROR: --run-id required" >&2; exit 2; }
[[ -n "${OPS_RUNLOG_DIR:-}" ]] || { echo "ERROR: OPS_RUNLOG_DIR not set" >&2; exit 2; }

DAY="${RUN_ID:0:4}-${RUN_ID:4:2}-${RUN_ID:6:2}"
RUNLOG="${OPS_RUNLOG_DIR}/${DAY}/${RUN_ID}.jsonl"
OPS_RUN_DIR="${OPS_RUN_DIR:-${OPS_RUNLOG_DIR}/${DAY}}"
INVEST_DIR="${OPS_RUN_DIR}/investigations/${RUN_ID}"

[[ -f "$RUNLOG" ]] || { echo "ERROR: runlog missing: $RUNLOG" >&2; exit 2; }
[[ -d "$INVEST_DIR" ]] || mkdir -p "$INVEST_DIR"

# Build expected map from profile_group_fetched.
expected=$(jq -s -c '
  [.[] | select(.event == "profile_group_fetched")]
  | unique_by(.profile_id)
  | map({profile_id, cr_ids: (.cr_ids // []), credited_name: (.credited_name // ""), track_title: (.track_title // ""), role: (.role // "")})
' "$RUNLOG")

# For each expected profile: try to read its investigation JSON; if missing
# emit a placeholder entry with status:"missing" so the parent can see gaps.
result=$(echo "$expected" | jq -c --arg dir "$INVEST_DIR" '
  map(
    . as $row
    | ($dir + "/" + .profile_id + ".json") as $f
    | $row + {invest_path: $f}
  )
')

assembled=$(echo "$result" | jq -c '
  map(
    . as $row
    | ($row.invest_path) as $f
    | (try (input_filename = $f | input) catch null) as $invest
    | $row + {
        verdict: ($invest.verdict // null),
        reason: ($invest.reason // null),
        evidence_excerpts: ($invest.evidence_excerpts // []),
        browser_load_urls: ($invest.browser_load_urls // []),
        status: (if $invest == null then "missing" else "ready" end)
      }
    | del(.invest_path)
  )
' 2>/dev/null || echo "$result" | jq -c 'map(. + {verdict:null, reason:null, evidence_excerpts:[], browser_load_urls:[], status:"missing"})')

# jq's `try input` per row across files is fiddly; use a slurp variant instead
# that's robust on empty/missing files.
assembled=$(echo "$result" | jq -c --arg dir "$INVEST_DIR" '
  map(
    . as $row
    | ($dir + "/" + .profile_id + ".json") as $f
    | $row + {file: $f}
  )
')

out_array="["
sep=""
missing_count=0

while IFS= read -r row; do
  file=$(echo "$row" | jq -r '.file')
  if [[ -f "$file" ]] && jq empty "$file" 2>/dev/null; then
    invest=$(cat "$file")
    merged=$(jq -n --argjson row "$row" --argjson inv "$invest" '
      ($row | del(.file)) + {
        verdict: ($inv.verdict // null),
        reason: ($inv.reason // null),
        evidence_excerpts: ($inv.evidence_excerpts // []),
        browser_load_urls: ($inv.browser_load_urls // []),
        reasoning_summary: ($inv.reasoning_summary // ""),
        status: "ready"
      }
    ')
  else
    merged=$(jq -nc --argjson row "$row" '
      ($row | del(.file)) + {
        verdict: null, reason: null,
        evidence_excerpts: [], browser_load_urls: [],
        reasoning_summary: "",
        status: "missing"
      }
    ')
    missing_count=$((missing_count + 1))
  fi
  out_array="${out_array}${sep}${merged}"
  sep=","
done < <(echo "$assembled" | jq -c '.[]')
out_array="${out_array}]"

# Validate assembled JSON
if ! echo "$out_array" | jq empty 2>/dev/null; then
  echo "ERROR: assembled output is not valid JSON" >&2
  exit 2
fi

if (( REQUIRE_ALL == 1 && missing_count > 0 )); then
  echo "ERROR: --require-all set but $missing_count investigation file(s) missing" >&2
  echo "$out_array" | jq -c '[.[] | select(.status == "missing") | .profile_id]' >&2
  exit 4
fi

echo "$out_array"
