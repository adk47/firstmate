#!/usr/bin/env bash
# verify-credit-request-status.sh — Trino readback for credit-request status
# changes.
#
# Why this exists: the admin bulk PUT /admin/credit-requests returns HTTP 200
# even when zero rows actually transitioned — updateStatus.js's backend
# transition allowlist silently skips rows that aren't in an eligible source
# state (see batch-flag-credits.sh's "Failure-semantics caveat" header
# comment). A 2xx from that endpoint proves the request was ACCEPTED, not
# that every id landed in the intended status. This script closes that gap by
# reading the actual `status` column back from Postgres (via Trino) for the
# exact ids the caller intended to transition, and classifying each id as
# matched / mismatched / missing.
#
# This is a READ-ONLY verifier. It NEVER calls the admin write API and NEVER
# falls back to the admin `GET /admin/credit-requests` list endpoint — that
# endpoint has no id filter, so it cannot answer "did THESE ids transition"
# without an unbounded scan-and-hope. Trino against postgresql_core is the
# only source of truth this script trusts.
#
# Usage:
#   verify-credit-request-status.sh \
#       --expected <pending|processing|approved|rejected|unverified|user_verification_needed> \
#       --ids "<id1>,<id2>,..." \
#       [--results-line 0|1]   (default 1 — append a truth-floor row)
#
# Output (stdout, exactly one compact JSON line):
#   {"expected":"...","matched":N,"mismatched":[{"id":"...","actual":"..."}]}
#
# Exit codes:
#   0   every requested id came back with the expected status
#   1   at least one id came back with a different status, or was missing
#       entirely from the result set (actual:"missing")
#   2   argument validation failure (no Trino call attempted)
#   3   UNVERIFIABLE — the Trino wrapper itself failed (non-zero exit,
#       timeout, or empty/malformed output when ids were requested). This is
#       NOT the same as "0 matched" — it means the readback could not run at
#       all, so the write must NOT be treated as verified either way.
#
# Env:
#   TRINO_QUERY_SH             path to trino-query.sh. Same resolution chain
#                              as fraud-muso-only-lookup.sh: env override ->
#                              relative repo-root path -> deployed
#                              /opt/hydra/scripts/trino-query.sh.
#   CV_VERIFY_TRINO_TIMEOUT    seconds, default 60. Wall-clock cap (via
#                              `timeout`) on the trino-query.sh call. A
#                              point lookup by primary key on
#                              postgresql_core.credit_requests should return
#                              in well under this.
#   CV_RESULTS_PATH            overrides the truth-floor results file path
#                              (useful for tests). See write_results_line
#                              below for the default derivation.
#   OPS_RUN_ID / RUN_ID / OPS_RUNLOG_DIR   run-id resolution for the
#                              truth-floor row. Mirrors muso-admin-api.sh's
#                              write_credit_request_result.
#
# No side effects beyond the read-only Trino SELECT and (optionally)
# appending one line to the results JSONL truth floor.

set -euo pipefail

CV_VERIFY_TRINO_TIMEOUT="${CV_VERIFY_TRINO_TIMEOUT:-60}"

EXPECTED_STATUS_REGEX="^(pending|processing|approved|rejected|unverified|user_verification_needed)$"
UUID_REGEX='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

EXPECTED=""
IDS_RAW=""
RESULTS_LINE=1

usage() {
    cat >&2 <<EOF
Usage:
  verify-credit-request-status.sh \\
      --expected <pending|processing|approved|rejected|unverified|user_verification_needed> \\
      --ids "<id1>,<id2>,..." \\
      [--results-line 0|1]

Required:
  --expected     The status every listed id is expected to have transitioned
                 to. Closed-list enum matching CreditRequests.STATUSES.
  --ids          Comma-separated list of credit-request UUIDs to read back.
                 Every id MUST be a strict UUID — validated before any SQL is
                 built. An invalid id is a usage error (exit 2); no Trino
                 call is attempted.

Optional:
  --results-line 0|1   Whether to append a truth-floor row to the
                       credit-batch-runs results JSONL. Default 1.

Exit codes:
  0    every id verified at the expected status
  1    at least one id mismatched or was missing from the readback
  2    argument validation failure (no Trino call attempted)
  3    UNVERIFIABLE — the Trino readback itself failed; treat the write as
       NOT verified either way, do not fall back to the admin list API.

Stdout: one compact JSON line: {"expected":...,"matched":N,"mismatched":[...]}.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expected)
            EXPECTED="${2:-}"
            shift 2
            ;;
        --ids)
            IDS_RAW="${2:-}"
            shift 2
            ;;
        --results-line)
            RESULTS_LINE="${2:-}"
            shift 2
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

if [[ -z "$EXPECTED" ]]; then
    echo "ERROR: --expected is required." >&2
    exit 2
fi
if ! [[ "$EXPECTED" =~ $EXPECTED_STATUS_REGEX ]]; then
    echo "ERROR: --expected '$EXPECTED' is not a valid status enum value." >&2
    echo "       Valid: pending, processing, approved, rejected, unverified, user_verification_needed" >&2
    exit 2
fi
if [[ -z "$IDS_RAW" ]]; then
    echo "ERROR: --ids is required (comma-separated credit-request UUIDs)." >&2
    exit 2
fi
if [[ "$RESULTS_LINE" != "0" && "$RESULTS_LINE" != "1" ]]; then
    echo "ERROR: --results-line must be 0 or 1." >&2
    exit 2
fi

# Parse + strictly validate every id as a UUID BEFORE it can ever reach SQL
# interpolation. This is an injection guard, not just data hygiene — reject
# the whole request rather than drop bad tokens, since a dropped id here
# would silently under-verify a batch.
IFS=',' read -r -a ID_ARR <<< "$IDS_RAW"
for i in "${!ID_ARR[@]}"; do
    id_trimmed="${ID_ARR[$i]#"${ID_ARR[$i]%%[![:space:]]*}"}"
    id_trimmed="${id_trimmed%"${id_trimmed##*[![:space:]]}"}"
    if [[ -z "$id_trimmed" ]]; then
        echo "ERROR: --ids contains an empty entry. Use a comma-separated list with no empty values." >&2
        exit 2
    fi
    if ! [[ "$id_trimmed" =~ $UUID_REGEX ]]; then
        echo "ERROR: --ids contains a non-UUID entry: '$id_trimmed'. No Trino call attempted." >&2
        exit 2
    fi
    ID_ARR[i]="$id_trimmed"
done

# --- Resolve trino-query.sh -------------------------------------------------
# Mirrors fraud-muso-only-lookup.sh's resolution chain exactly (lines ~71-75
# of that file): env override -> relative repo-root path -> deployed
# /opt/hydra path. This script lives at .../muso-ops-credit-verification/
# scripts/ (one level shallower than fraud-muso-only-lookup.sh's scripts/lib/),
# so repo root is five levels up here, not six.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${TRINO_QUERY_SH:-}" ]]; then
    TRINO_SH="$TRINO_QUERY_SH"
elif [[ -x "$HERE/../../../../../scripts/trino-query.sh" ]]; then
    TRINO_SH="$HERE/../../../../../scripts/trino-query.sh"
elif [[ -x /opt/hydra/scripts/trino-query.sh ]]; then
    TRINO_SH=/opt/hydra/scripts/trino-query.sh
else
    TRINO_SH="$HERE/../../../../../scripts/trino-query.sh"
fi

unverifiable() {
    {
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "[verify-credit-request-status] UNVERIFIABLE: $1"
        echo "The Trino readback could not run. Do NOT treat this write as"
        echo "verified — matched/mismatched status is UNKNOWN, not zero."
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    } >&2
    write_results_line "readback_unverifiable" "$2" "$3"
    exit 3
}

# --- Truth-floor writer -----------------------------------------------------
# Mirrors muso-admin-api.sh's write_credit_request_result path resolution
# (lines ~266-283 of that file): CV_RESULTS_PATH override, else
# /var/log/openclaw/credit-batch-runs/<UTC yyyy-mm-dd>/<run_id>.results.jsonl,
# with run_id resolved from OPS_RUN_ID/RUN_ID/OPS_RUNLOG_DIR/latest.txt.
# Failures here are LOUD-WARN-NEVER-BLOCK, same philosophy as that function.
write_results_line() {
    [[ "$RESULTS_LINE" == "1" ]] || return 0

    local outcome="$1" matched="$2" mismatched_json="$3"

    local run_id
    run_id="${OPS_RUN_ID:-${RUN_ID:-}}"
    if [[ -z "$run_id" && -n "${OPS_RUNLOG_DIR:-}" && -f "${OPS_RUNLOG_DIR}/latest.txt" ]]; then
        local latest_path latest_base
        latest_path=$(cat "${OPS_RUNLOG_DIR}/latest.txt" 2>/dev/null || true)
        if [[ -n "$latest_path" ]]; then
            latest_base=$(basename "$latest_path" .jsonl)
            if [[ "$latest_base" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ ]]; then
                run_id="$latest_base"
            fi
        fi
    fi

    local results_path today
    today="$(date -u +%Y-%m-%d)"
    results_path="${CV_RESULTS_PATH:-/var/log/openclaw/credit-batch-runs/${today}/${run_id:-unknown}.results.jsonl}"

    local results_dir
    results_dir="$(dirname "$results_path")"
    if ! mkdir -p "$results_dir" 2>/dev/null; then
        echo "WARN: could not create results dir ${results_dir}; readback results line LOST." >&2
        return 0
    fi

    local ts request_ids_json
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    request_ids_json=$(printf '%s\n' "${ID_ARR[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')

    local line
    if ! line=$(jq -n -c \
        --arg ts "$ts" \
        --arg run_id "$run_id" \
        --arg path "/admin/credit-requests" \
        --argjson request_ids "$request_ids_json" \
        --arg intended_status "$EXPECTED" \
        --arg outcome "$outcome" \
        --argjson matched "${matched:-0}" \
        --argjson mismatched "${mismatched_json:-[]}" \
        '{
            ts:$ts,
            run_id: (if $run_id == "" then null else $run_id end),
            method: "READBACK",
            path:$path,
            request_ids:$request_ids,
            intended_status:$intended_status,
            outcome:$outcome,
            matched:$matched,
            mismatched:$mismatched
         }' 2>/dev/null); then
        echo "WARN: jq failed to build readback results line; line LOST." >&2
        return 0
    fi
    if ! printf '%s\n' "$line" >> "$results_path" 2>/dev/null; then
        echo "WARN: could not append to ${results_path}; readback results line LOST." >&2
        return 0
    fi
}

if ! command -v "$TRINO_SH" >/dev/null 2>&1 && [[ ! -x "$TRINO_SH" ]]; then
    unverifiable "trino-query.sh not found/executable at $TRINO_SH" 0 '[]'
fi

# --- Build + run the SQL -----------------------------------------------------
IN_LIST=$(printf '%s\n' "${ID_ARR[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))' | jq -r 'map("'\''" + . + "'\''") | join(",")')

SQL="SELECT id, status FROM postgresql_core.public.credit_requests WHERE id IN (${IN_LIST})"

TRINO_ERR="$(mktemp)" || unverifiable "could not create stderr tempfile" 0 '[]'
trap 'rm -f "$TRINO_ERR"' EXIT

err_tail() {
    tail -n 3 "$TRINO_ERR" 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/ $//'
}

rc=0
if ! command -v timeout >/dev/null 2>&1; then
    echo "[verify-credit-request-status] WARN: 'timeout' not available; running trino-query.sh without a wall-clock cap." >&2
    CSV=$(printf '%s\n' "$SQL" | bash "$TRINO_SH" 2>"$TRINO_ERR") || rc=$?
else
    CSV=$(printf '%s\n' "$SQL" | timeout "${CV_VERIFY_TRINO_TIMEOUT}s" bash "$TRINO_SH" 2>"$TRINO_ERR") || rc=$?
fi

if (( rc == 124 )); then
    unverifiable "trino query exceeded ${CV_VERIFY_TRINO_TIMEOUT}s timeout; trino stderr: $(err_tail)" 0 '[]'
fi
if (( rc != 0 )); then
    unverifiable "trino-query.sh exited rc=$rc; trino stderr: $(err_tail)" 0 '[]'
fi

# --- Parse CSV → JSON map of id -> status -----------------------------------
# trino --output-format CSV emits quoted fields, no header:
#   "<uuid>","<status>"
MAP=$(printf '%s' "$CSV" | jq -R -s '
  def trimq: gsub("^\"|\"$"; "");
  ( split("\n")
    | map(select(length > 0))
    | map(split(",") | map(trimq))
    | map(select(length >= 2))
    | map({ key: .[0], value: .[1] })
    | from_entries )' 2>/dev/null)

if [[ -z "$MAP" ]] || ! printf '%s' "$MAP" | jq -e . >/dev/null 2>&1; then
    unverifiable "could not parse trino CSV into a JSON map; trino output: $(printf '%s' "$CSV" | tr '\n' ' ' | head -c 200)" 0 '[]'
fi

CSV_NONBLANK=$(printf '%s' "$CSV" | tr -d '[:space:]')
MAP_LEN=$(printf '%s' "$MAP" | jq 'length')
if [[ -z "$CSV_NONBLANK" ]]; then
    # Empty output when ids WERE requested is UNVERIFIABLE, not "all missing" —
    # we cannot distinguish a clean empty result (impossible here, since the
    # WHERE clause is an explicit id list) from a silently truncated response.
    unverifiable "trino returned empty output for a non-empty id list — cannot verify" 0 '[]'
fi
if [[ "$MAP_LEN" == "0" ]]; then
    unverifiable "trino returned non-empty output that yielded no parseable rows (likely an error page, not a clean result)" 0 '[]'
fi

# --- Classify each requested id ---------------------------------------------
matched=0
mismatched_json="[]"
for id in "${ID_ARR[@]}"; do
    actual=$(printf '%s' "$MAP" | jq -r --arg id "$id" '.[$id] // empty')
    if [[ -z "$actual" ]]; then
        mismatched_json=$(printf '%s' "$mismatched_json" | jq -c --arg id "$id" '. + [{id:$id, actual:"missing"}]')
    elif [[ "$actual" == "$EXPECTED" ]]; then
        matched=$((matched + 1))
    else
        mismatched_json=$(printf '%s' "$mismatched_json" | jq -c --arg id "$id" --arg actual "$actual" '. + [{id:$id, actual:$actual}]')
    fi
done

mismatched_count=$(printf '%s' "$mismatched_json" | jq 'length')

if [[ "$mismatched_count" -eq 0 ]]; then
    outcome="readback_ok"
    rc=0
else
    outcome="readback_mismatch"
    rc=1
fi

write_results_line "$outcome" "$matched" "$mismatched_json"

jq -n -c \
    --arg expected "$EXPECTED" \
    --argjson matched "$matched" \
    --argjson mismatched "$mismatched_json" \
    '{expected:$expected, matched:$matched, mismatched:$mismatched}'

exit $rc
