#!/usr/bin/env bash
# batch-flag-credits.sh — the ONLY sanctioned way for the ops agent to flag
# credit requests for user_verification_needed in batch.
#
# Symmetry with batch-approve-credits.sh (PR 2 of the 2026-04-22 silent-
# failure fix). Flagging is not gated by enforce_credit_approve_gate —
# user_verification_needed never required browser evidence — but every other
# failure mode is identical: an agent that swallows stderr + counts loop
# iterations will claim success regardless. This wrapper takes that surface
# away by checking exit code + envelope shape and refusing to claim success
# without a 2xx (or dry-run intercept) from the API.
#
# Endpoint: PUT /admin/credit-requests with body
#   {"requestIds":[...],"status":"user_verification_needed"}
# This is the SAME route batch-approve-credits.sh uses — the backend
# `updateStatus` handler (`core-backend/src/apis/_admin/credit-requests/
# updateStatus.js`) accepts every value of CreditRequests.STATUSES,
# including USER_VERIFICATION_NEEDED. Per-id PATCH was never registered
# in core-backend's routing table (`core-backend/src/apis/index.w.js`);
# the prior implementation here issued PATCH /admin/credit-requests/<id>
# in a loop and got HTTP 404 ("Cannot PATCH …") for every id — the
# 2026-04-27 15:42 UTC real run is the post-mortem (25/25 errored).
#
# !! Failure-semantics caveat (was: per-id loop, now: single PUT + readback) !!
# updateStatus.js processes the requestIds array via Promise.mapSeries
# with no visible transaction wrapper. Partial in-loop failures inside
# the API DO NOT surface in the HTTP response — a 200 OK does not prove
# every id transitioned. This wrapper now performs an automatic Trino
# readback (verify-credit-request-status.sh) after every accepted PUT to
# close that gap: it re-reads the actual `status` column for the exact ids
# just PUT and fails loud (exit 3/4 below) if any id didn't land on
# user_verification_needed. Skip with --no-verify only for callers that do
# their own reconciliation. Reconciliation should still cross-check both
# the readback row in .results.jsonl AND compute-run-summary.sh reading
# .results.jsonl against a fresh queue fetch — the readback is a per-call
# guard, not a substitute for the batch-level summary.
#
# Usage:
#   batch-flag-credits.sh \
#       --profile-id <profile_id> \
#       --credited-name "<name>" \
#       --track-title  "<track title>" \
#       --role         "<role[,role2,...]>" \
#       --reason "<short reason>" \
#       --flag-reason <enum> \
#       --ids "<id1>,<id2>,<id3>"
#
# --credited-name / --track-title / --role are forwarded to the admin-API
# wrapper via OPS_CREDITED_NAME / OPS_TRACK_TITLE / OPS_ROLE env vars so the
# .results.jsonl truth-floor row records what claim was being flagged.
#
# Contract:
#   * One PUT /admin/credit-requests for the entire batch. The backend
#     atomically transitions each matching request from UNVERIFIED to
#     USER_VERIFICATION_NEEDED (per updateStatus.js line 51-56).
#   * --reason is REQUIRED for caller discipline (don't UVN without an
#     intent), but is NOT sent to the backend — updateStatus does not
#     consume a reason field. The reason is forwarded to stderr so it
#     lands in the agent transcript / audit capture.
#   * --requester is REFUSED. Consistent with batch-approve-credits.sh.
#   * Exit 0 on HTTP 2xx or dry-run intercept, AND (unless --no-verify) the
#     automatic Trino readback confirms every id landed on
#     user_verification_needed.
#   * Exit 1 on API failure (HTTP error, network error).
#   * Exit 2 on arg validation failures. No API call is attempted.
#   * Exit 3 on readback mismatch — the PUT was accepted but the readback
#     found at least one id NOT at user_verification_needed.
#   * Exit 4 on readback UNVERIFIABLE — the Trino readback itself failed
#     (never treat this as "verified"; see verify-credit-request-status.sh).
#   * Stdout: a single compact JSON summary line, including a "readback"
#     field with the verify script's JSON (or "skipped" for dry-run /
#     --no-verify). Per-call truth lives in .results.jsonl (PR #158
#     truth-floor, plus the READBACK row) — this stdout is a convenience.

set -euo pipefail

ADMIN_API_SH="${ADMIN_API_SH:-/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"
VERIFY_STATUS_SH="${VERIFY_STATUS_SH:-/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/verify-credit-request-status.sh}"

# Closed-list flag reasons (added 2026-04-30, tightened same day after the
# evidence_quorum_failed/human_review_requested bypass loophole leaked 460
# credits — see batch-verify-profile.sh head comment for the incident notes).
# Same enum as batch-verify-profile.sh; the dispatcher validates it before
# calling here, but we accept + forward to .results.jsonl unchanged so the
# truth-floor row carries the structured signal.
#
# fraud_multifactor (added 2026-06-08) carries the multi-factor batch fraud
# detector's verdict (score-fraud-signals.sh, CV_FRAUD_MODE=enforce). It is
# STILL a closed-list value — the human-readable factor breakdown
# (fraud:role_inflation+source_quality+...=0.80) rides in --reason, not here,
# so this enum stays a small fixed set. See docs/credit-verification/
# fraud-detection-spec.md §9 (the matching DB-enum extension is deferred).
FLAG_REASONS_REGEX="^(name_mismatch|popularity_anomaly|no_tier1_match|metadata_inconsistent|fraud_multifactor)$"

PROFILE_ID=""
CREDITED_NAME=""
TRACK_TITLE=""
ROLE=""
REASON=""
FLAG_REASON=""
IDS_RAW=""
NO_VERIFY=0

usage() {
    cat >&2 <<EOF
Usage:
  batch-flag-credits.sh \\
      --profile-id <profile_id> \\
      --reason "<short reason>" \\
      --flag-reason <enum> \\
      --ids "<id1>,<id2>,..." \\
      [--no-verify]

Required:
  --profile-id   The profile UUID whose credits are being flagged. Used only
                 for stdout bookkeeping and .results.jsonl reconciliation.
  --reason       A short prose string describing why these are UVN. Forwarded
                 to stderr / agent transcript only — the backend updateStatus
                 handler does NOT consume a reason field. Required for caller
                 discipline so flagging is never reasonless.
  --flag-reason  Closed-list enum (categorical signal logged to .results.jsonl
                 as flag_reason). One of: name_mismatch, popularity_anomaly,
                 no_tier1_match, metadata_inconsistent, fraud_multifactor.
  --ids          Comma-separated list of credit-request IDs to flag.

Optional:
  --no-verify   Skip the automatic Trino readback after an accepted PUT.
                Only for callers that perform their own reconciliation.

Forbidden:
  --requester   Not allowed. This wrapper is for autonomous batches only.

Exit codes:
  0    success (HTTP 2xx or dry-run intercept, and readback confirmed unless
       --no-verify)
  1    API failure (HTTP error, network error)
  2    argument validation failure (no API call attempted)
  3    readback mismatch — PUT accepted, but the Trino readback found at
       least one id NOT at user_verification_needed
  4    readback UNVERIFIABLE — the Trino readback itself failed; treat as
       NOT verified, do not assume success

Stdout: one compact JSON line summarising the batch outcome, including a
        "readback" field (or "skipped" for dry-run / --no-verify).
Stderr: muso-admin-api.sh's stderr forwarded verbatim.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile-id)
            PROFILE_ID="${2:-}"
            shift 2
            ;;
        --credited-name)
            CREDITED_NAME="${2:-}"
            shift 2
            ;;
        --track-title)
            TRACK_TITLE="${2:-}"
            shift 2
            ;;
        --role)
            ROLE="${2:-}"
            shift 2
            ;;
        --reason)
            REASON="${2:-}"
            shift 2
            ;;
        --flag-reason)
            FLAG_REASON="${2:-}"
            shift 2
            ;;
        --ids)
            IDS_RAW="${2:-}"
            shift 2
            ;;
        --no-verify)
            NO_VERIFY=1
            shift
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
if [[ -z "$FLAG_REASON" ]]; then
    echo "ERROR: --flag-reason is required (closed-list enum: name_mismatch, popularity_anomaly, no_tier1_match, metadata_inconsistent, fraud_multifactor)." >&2
    exit 2
fi
if ! [[ "$FLAG_REASON" =~ $FLAG_REASONS_REGEX ]]; then
    echo "ERROR: --flag-reason '$FLAG_REASON' is not a valid enum value." >&2
    echo "       Valid: name_mismatch, popularity_anomaly, no_tier1_match, metadata_inconsistent, fraud_multifactor" >&2
    exit 2
fi
if [[ -z "$IDS_RAW" ]]; then
    echo "ERROR: --ids is required (comma-separated credit-request IDs)." >&2
    exit 2
fi

# Parse + trim IDs. Reject empty entries from "a,,b" or leading/trailing
# commas so we never send `"requestIds":[""]` to the API, which the
# backend would silently ignore.
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

# Forward the human-readable reason + categorical flag_reason to stderr so
# they land in the agent transcript / openclaw session log even though the
# API doesn't store them. Audit grep-ability without API surface coupling.
echo "[batch-flag-credits] profile=$PROFILE_ID reason=\"$REASON\" flag_reason=$FLAG_REASON ids=${#ID_ARR[@]}" >&2

# Propagate the closed-list flag_reason + claim metadata to muso-admin-api.sh's
# truth-floor writer (write_credit_request_result reads OPS_FLAG_REASON +
# OPS_CREDITED_NAME / OPS_TRACK_TITLE / OPS_ROLE when present). Exported only
# for the duration of this single PUT — admin-api inherits it in the subshell,
# downstream callers of this script do not.
export OPS_FLAG_REASON="$FLAG_REASON"
export OPS_CREDITED_NAME="$CREDITED_NAME"
export OPS_TRACK_TITLE="$TRACK_TITLE"
export OPS_ROLE="$ROLE"

# Build the JSON body via jq so embedded shell metacharacters in IDs (if
# any ever contain them) don't get interpolated into a string-concat body.
body=$(jq -n -c \
    --arg raw "$IDS_RAW" \
    '{
        requestIds: ($raw | split(",") | map(. | gsub("^\\s+|\\s+$"; ""))),
        status: "user_verification_needed"
     }')

requested=${#ID_ARR[@]}

# DELIBERATELY DO NOT redirect stderr — HTTP errors and network failures
# must surface to the agent transcript. Capture stdout to classify the
# outcome.
response=""
rc=0
response=$(bash "$ADMIN_API_SH" \
    call PUT /admin/credit-requests "$body") || rc=$?

outcome="unknown"
http_status=""
if [[ $rc -eq 0 ]]; then
    # Branch on dryRun first (truth floor classifies as dry_run_intercept),
    # then on http_status 2xx. Anything else downgrades to http_error even
    # though rc=0 — belt + braces against a future admin-api refactor that
    # returns 0 on API failures.
    if printf '%s' "$response" | jq -e '.dryRun == true' >/dev/null 2>&1; then
        outcome="dry_run_intercept"
        http_status=$(printf '%s' "$response" | jq -r '.http_status // empty' 2>/dev/null)
    else
        http_status=$(printf '%s' "$response" | jq -r '.http_status // empty' 2>/dev/null)
        if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
            outcome="ok"
        else
            outcome="http_error"
            rc=1
        fi
    fi
else
    # Non-zero rc: most likely a curl-layer failure (network error,
    # connection refused). The admin script's stderr has already printed
    # the human-readable reason. Normalize to 1.
    outcome="http_error"
    rc=1
fi

# --- Automatic Trino readback ------------------------------------------------
# Only when the PUT was actually accepted (outcome=="ok" — NOT
# dry_run_intercept, since there's nothing real to read back, and NOT
# http_error, since the request was already rejected). Skippable via
# --no-verify for callers that do their own reconciliation.
readback_json="\"skipped\""
if [[ "$outcome" == "ok" && "$NO_VERIFY" -eq 0 ]]; then
    # Same trimmed ids the PUT body used, comma-joined for verify's --ids.
    verify_ids=$(printf '%s\n' "${ID_ARR[@]}" | paste -sd ',' -)
    verify_out=""
    verify_rc=0
    verify_out=$("$VERIFY_STATUS_SH" --expected user_verification_needed --ids "$verify_ids") || verify_rc=$?
    if [[ $verify_rc -eq 0 ]]; then
        readback_json="$verify_out"
    elif [[ $verify_rc -eq 1 ]]; then
        readback_json="$verify_out"
        rc=3
    else
        # verify_rc 2 (usage) should be impossible here since we built the
        # args ourselves, but 3 (unverifiable) and any other non-zero both
        # collapse to "readback could not run" — never treat as verified.
        readback_json='"unverifiable"'
        rc=4
    fi
fi

# Emit the summary line. Authoritative per-call truth is in .results.jsonl —
# this stdout is just a compact convenience for the caller.
jq -n -c \
    --arg profile_id "$PROFILE_ID" \
    --argjson requested "$requested" \
    --arg outcome "$outcome" \
    --arg http_status "$http_status" \
    --argjson readback "$readback_json" \
    '{
        profile_id: $profile_id,
        requested: $requested,
        outcome: $outcome,
        http_status: (if $http_status == "" then null else ($http_status | tonumber? // $http_status) end),
        readback: $readback
     }'

exit $rc
