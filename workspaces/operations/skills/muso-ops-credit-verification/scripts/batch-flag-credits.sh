#!/usr/bin/env bash
# batch-flag-credits.sh — the ONLY sanctioned way for the ops agent to flag
# credit requests for user_verification_needed in batch.
#
# Symmetry with batch-approve-credits.sh (PR 2 of the 2026-04-22 silent-
# failure fix). Flagging is not gated by enforce_credit_approve_gate —
# user_verification_needed never required browser evidence — but every other
# failure mode is identical: an agent that swallows stderr + counts loop
# iterations will claim success regardless. This wrapper takes that surface
# away by checking each exit code and refusing to continue past failures
# without counting them honestly.
#
# Unlike approve (which batches via PUT /admin/credit-requests), the backend
# only supports per-id PATCH for user_verification_needed — that matches
# what production has been doing successfully (167 UVN writes on 2026-04-22
# 19:19 UTC). So the loop is unavoidable; the discipline is to propagate
# every failure and emit a structured per-ID result.
#
# Usage:
#   batch-flag-credits.sh \
#       --profile-id <profile_id> \
#       --reason "<short reason>" \
#       --ids "<id1>,<id2>,<id3>"
#
# Contract:
#   * One PATCH /admin/credit-requests/<id> per ID, body {"status":
#     "user_verification_needed","reason":"<reason>"}.
#   * --requester is REFUSED. Consistent with batch-approve-credits.sh.
#   * Exit 0 iff EVERY id succeeded (HTTP 2xx or dry-run intercept).
#   * Exit 1 if one or more ids failed. Failing fast would leave partial
#     state hard to reconcile; instead we attempt every id, tally failures,
#     and report them in the stdout summary.
#   * Exit 2 on arg validation failures. No API call is attempted.
#   * Stdout: a single compact JSON summary line. Per-id truth lives in
#     .results.jsonl (PR #158 truth-floor) — this stdout is a convenience.

set -euo pipefail

ADMIN_API_SH="${ADMIN_API_SH:-/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"

PROFILE_ID=""
REASON=""
IDS_RAW=""

usage() {
    cat >&2 <<EOF
Usage:
  batch-flag-credits.sh \\
      --profile-id <profile_id> \\
      --reason "<short reason>" \\
      --ids "<id1>,<id2>,..."

Required:
  --profile-id  The profile UUID whose credits are being flagged. Used only
                for stdout bookkeeping and .results.jsonl reconciliation.
  --reason      A short string for the 'reason' field on each PATCH. Typical
                values: "high_velocity", "unverifiable", "record_label_role".
  --ids         Comma-separated list of credit-request IDs to flag.

Forbidden:
  --requester   Not allowed. This wrapper is for autonomous batches only.

Exit codes:
  0    every id succeeded (HTTP 2xx or dry-run intercept)
  1    one or more ids failed — details in stdout summary
  2    argument validation failure (no API call attempted)

Stdout: one compact JSON line with requested/succeeded/failed counts.
Stderr: muso-admin-api.sh's stderr forwarded verbatim for each call.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile-id)
            PROFILE_ID="${2:-}"
            shift 2
            ;;
        --reason)
            REASON="${2:-}"
            shift 2
            ;;
        --ids)
            IDS_RAW="${2:-}"
            shift 2
            ;;
        --requester)
            echo "ERROR: --requester is forbidden in batch-flag-credits.sh." >&2
            exit 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -z "$PROFILE_ID" ]]; then
    echo "ERROR: --profile-id is required." >&2
    exit 2
fi
if [[ -z "$REASON" ]]; then
    echo "ERROR: --reason is required (short string describing why these are UVN)." >&2
    exit 2
fi
if [[ -z "$IDS_RAW" ]]; then
    echo "ERROR: --ids is required (comma-separated credit-request IDs)." >&2
    exit 2
fi

# Parse + trim IDs. Same defensive treatment as batch-approve-credits.sh:
# reject empty entries rather than sending "user_verification_needed" to an
# empty path like /admin/credit-requests/.
IFS=',' read -r -a ID_ARR <<< "$IDS_RAW"
for i in "${!ID_ARR[@]}"; do
    id_trimmed="${ID_ARR[$i]#"${ID_ARR[$i]%%[![:space:]]*}"}"
    id_trimmed="${id_trimmed%"${id_trimmed##*[![:space:]]}"}"
    if [[ -z "$id_trimmed" ]]; then
        echo "ERROR: --ids contains an empty entry. Use a comma-separated list with no empty values." >&2
        exit 2
    fi
    ID_ARR[i]="$id_trimmed"
done

if [[ ! -f "$ADMIN_API_SH" ]]; then
    echo "ERROR: muso-admin-api.sh not found at $ADMIN_API_SH — set ADMIN_API_SH env var to override for local tests." >&2
    exit 2
fi

# PATCH body shape is the same for every id in the batch.
body=$(jq -n -c \
    --arg reason "$REASON" \
    '{status: "user_verification_needed", reason: $reason}')

requested=${#ID_ARR[@]}
succeeded=0
failed=0
declare -a failed_ids=()

# Per-id loop. Do NOT swallow stderr; do NOT redirect stdout. Each call's
# exit code is checked, and failures don't terminate the loop — we want to
# try every id so the reconciliation surface in .results.jsonl reflects
# the full attempted batch.
for id in "${ID_ARR[@]}"; do
    local_rc=0
    response=$(bash "$ADMIN_API_SH" \
        call PATCH "/admin/credit-requests/${id}" "$body") || local_rc=$?

    if [[ $local_rc -ne 0 ]]; then
        failed=$((failed + 1))
        failed_ids+=("$id")
        continue
    fi

    # Success shapes: dryRun:true OR http_status 2xx. Anything else counts
    # as a failure even with rc=0, mirroring batch-approve-credits.sh.
    if printf '%s' "$response" | jq -e '.dryRun == true' >/dev/null 2>&1; then
        succeeded=$((succeeded + 1))
    else
        http_status=$(printf '%s' "$response" | jq -r '.http_status // empty' 2>/dev/null || echo "")
        if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
            succeeded=$((succeeded + 1))
        else
            failed=$((failed + 1))
            failed_ids+=("$id")
        fi
    fi
done

# Build the summary. failed_ids is always present (empty array when none
# failed) so downstream parsers don't need conditional null handling.
failed_ids_json="[]"
if [[ ${#failed_ids[@]} -gt 0 ]]; then
    failed_ids_json=$(printf '%s\n' "${failed_ids[@]}" | jq -R . | jq -s -c)
fi

jq -n -c \
    --arg profile_id "$PROFILE_ID" \
    --argjson requested "$requested" \
    --argjson succeeded "$succeeded" \
    --argjson failed "$failed" \
    --argjson failed_ids "$failed_ids_json" \
    '{
        profile_id: $profile_id,
        requested: $requested,
        succeeded: $succeeded,
        failed: $failed,
        failed_ids: $failed_ids,
        outcome: (if $failed == 0 then "ok" else "partial_failure" end)
     }'

if [[ $failed -gt 0 ]]; then
    exit 1
fi
exit 0
