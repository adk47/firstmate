#!/usr/bin/env bash
# count-approvals.sh — count today's autonomous approvals in the audit log.
# Output: integer count on stdout.
# Env:
#   OPS_AUDIT_LOG_DIR   required — directory containing YYYY-MM-DD.jsonl files
#
# Exit codes:
#   0  ok
#   2  env not set
#   4  audit log has corrupt (non-JSON) lines — refuse to undercount silently
#   5  audit log not readable

set -euo pipefail

if [[ -z "${OPS_AUDIT_LOG_DIR:-}" ]]; then
  echo "ERROR: OPS_AUDIT_LOG_DIR is not set" >&2
  exit 2
fi

TODAY=$(date -u +%Y-%m-%d)
LOG_FILE="${OPS_AUDIT_LOG_DIR}/${TODAY}.jsonl"

if [[ ! -e "$LOG_FILE" ]]; then
  echo "0"
  exit 0
fi
if [[ ! -f "$LOG_FILE" || ! -r "$LOG_FILE" ]]; then
  # Not a regular readable file — refuse to silently return 0.
  # If the cap counter returned 0 here, the bot would treat it as "no approvals
  # today" and uncap itself. Fail loud.
  echo "ERROR: $LOG_FILE is not a readable regular file" >&2
  exit 5
fi

# Single strict pass: parse every line (no `fromjson?` — we want it to fail on
# the first corrupt line, not silently undercount), filter to autonomous
# approvals, count.
#
# The earlier two-pass implementation reused `fromjson?` for validation, which
# contradicted the "refuse to undercount" intent: `fromjson?` swallows parse
# errors per-line, so the validation pass was just counting parseable lines.
# The math still caught corruption (TOTAL-vs-PARSED diff), but the inner
# operator was the wrong tool. Strict `fromjson` is what we actually want.
if ! COUNT=$(jq -Rsr '
      split("\n")
      | map(select(. != ""))
      | map(fromjson | select(.operator == "clio" and .requester == "clio" and .status == "approved"))
      | length
    ' "$LOG_FILE" 2>/dev/null); then
  echo "ERROR: $LOG_FILE has corrupt (non-JSON) line(s); refusing to undercount" >&2
  exit 4
fi
echo "$COUNT"
