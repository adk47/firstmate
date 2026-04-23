#!/usr/bin/env bash
# batch-approve-credits.sh — the ONLY sanctioned way for the ops agent to
# approve credit requests in batch.
#
# Why this exists:
#   The 2026-04-22 19:15 UTC live dry-run showed the agent synthesizing its
#   own bash helpers, passing evidence in the JSON body (which the gate
#   ignores — it reads only the --evidence-excerpt CLI flag), wrapping calls
#   in `> /dev/null`, and counting loop iterations as successes. Zero of 333
#   claimed approvals actually landed; Slack reported full success.
#
#   Rather than trust the LLM to get the invocation right every time, this
#   wrapper narrows the agent's surface to a single shape that is IMPOSSIBLE
#   to combine with the three failure modes:
#     1. --evidence-excerpt is a REQUIRED named arg here; no JSON-body form.
#     2. The wrapper does not redirect stderr. Gate errors surface verbatim.
#     3. The wrapper exits non-zero on any failure and propagates the exit
#        code from muso-admin-api.sh. There is no iteration counter.
#
#   Authoritative per-call outcome lands in the .results.jsonl that PR #158
#   added inside muso-admin-api.sh itself (truth-floor design: disk, not
#   streams). compute-run-summary.sh is the sole source of the Slack summary,
#   derived from .results.jsonl — not from this wrapper's stdout.
#
# Usage:
#   batch-approve-credits.sh \
#       --profile-id <profile_id> \
#       --evidence-excerpt "<literal substring from ≥2 Tier 1 browser loads>" \
#       --ids "<id1>,<id2>,<id3>"
#
# Contract:
#   * One batched PUT /admin/credit-requests per invocation (one profile's
#     worth of credits). The --evidence-excerpt is a single literal substring
#     that must appear verbatim on ≥2 distinct Tier 1 pages already loaded
#     via the `browser` tool in the active session. SKILL.md section "Evidence
#     requirements" explains what qualifies.
#   * --requester is REFUSED. This wrapper is for autonomous batches only.
#     Jan/Aaron's manual per-credit override path goes through direct
#     muso-admin-api.sh invocation documented in muso-ops-admin/SKILL.md.
#   * Exit 0 iff muso-admin-api.sh returned 0 AND the response envelope
#     reports a 2xx or dryRun=true outcome.
#   * Exit 2 on arg validation failures (missing/malformed args). Exits
#     before any API call is attempted, so the truth-floor log is not
#     polluted with invalid requests.
#   * Exit 1 on API failures (gate rejection, HTTP error, network error).
#     muso-admin-api.sh's stderr is forwarded verbatim.
#   * Stdout: a single compact JSON summary line, e.g.
#       {"profile_id":"p1","requested":12,"outcome":"dry_run_intercept","http_status":200}
#     Authoritative per-request truth lives in .results.jsonl — this stdout
#     is purely a convenience for the caller's own logging.

set -euo pipefail

# Admin API path. Overridable for tests; in production the skills-all sync
# puts muso-admin-api.sh at the sibling operations/skills path.
ADMIN_API_SH="${ADMIN_API_SH:-/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"

# Evidence-excerpt length bounds — mirror muso-admin-api.sh's CV_* defaults
# so we fail fast on the same criteria, before round-tripping through the
# admin script. Override via env for symmetry.
CV_EVIDENCE_EXCERPT_MIN="${CV_EVIDENCE_EXCERPT_MIN:-8}"
CV_EVIDENCE_EXCERPT_MAX="${CV_EVIDENCE_EXCERPT_MAX:-200}"

PROFILE_ID=""
EVIDENCE_EXCERPT=""
IDS_RAW=""

usage() {
    cat >&2 <<EOF
Usage:
  batch-approve-credits.sh \\
      --profile-id <profile_id> \\
      --evidence-excerpt "<literal substring from >=2 Tier 1 browser loads>" \\
      --ids "<id1>,<id2>,..."

Required:
  --profile-id         The profile UUID whose credits are being approved.
                       Used only for stdout bookkeeping and .results.jsonl
                       reconciliation — the API does not read it.
  --evidence-excerpt   A literal substring (>=${CV_EVIDENCE_EXCERPT_MIN},
                       <=${CV_EVIDENCE_EXCERPT_MAX} chars) that appears
                       verbatim on >=2 distinct Tier 1 pages already loaded
                       via the \`browser\` tool in THIS session. Confabulated
                       or synthesized strings will be rejected by the gate.
  --ids                Comma-separated list of credit-request IDs to approve
                       in one batch. No spaces around commas.

Forbidden:
  --requester          This wrapper is for autonomous batches only. For
                       Jan/Aaron's manual per-credit overrides, call
                       muso-admin-api.sh directly per muso-ops-admin/SKILL.md.

Exit codes:
  0    success (HTTP 2xx or dry-run intercept)
  1    API failure (gate rejection, HTTP error, network error)
  2    argument validation failure (no API call attempted)

Stdout: one compact JSON line summarising the batch outcome.
Stderr: muso-admin-api.sh's stderr forwarded verbatim — gate errors included.
EOF
}

# Argument parsing — long opts only. Refuses --requester explicitly so the
# agent cannot accidentally reuse a human-override invocation shape in a
# batch context, which would bypass the gate.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile-id)
            PROFILE_ID="${2:-}"
            shift 2
            ;;
        --evidence-excerpt)
            EVIDENCE_EXCERPT="${2:-}"
            shift 2
            ;;
        --ids)
            IDS_RAW="${2:-}"
            shift 2
            ;;
        --requester)
            echo "ERROR: --requester is forbidden in batch-approve-credits.sh." >&2
            echo "       This wrapper is for autonomous batches only. For a human-authorized" >&2
            echo "       per-credit override, call muso-admin-api.sh directly." >&2
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

# Validate required args BEFORE any API call. Failing here leaves no line
# in .results.jsonl — intentional, since no admin-api call is issued.
if [[ -z "$PROFILE_ID" ]]; then
    echo "ERROR: --profile-id is required." >&2
    exit 2
fi
if [[ -z "$EVIDENCE_EXCERPT" ]]; then
    echo "ERROR: --evidence-excerpt is required." >&2
    exit 2
fi
if (( ${#EVIDENCE_EXCERPT} < CV_EVIDENCE_EXCERPT_MIN )); then
    echo "ERROR: --evidence-excerpt must be >=${CV_EVIDENCE_EXCERPT_MIN} chars (got ${#EVIDENCE_EXCERPT})." >&2
    exit 2
fi
if (( ${#EVIDENCE_EXCERPT} > CV_EVIDENCE_EXCERPT_MAX )); then
    echo "ERROR: --evidence-excerpt must be <=${CV_EVIDENCE_EXCERPT_MAX} chars (got ${#EVIDENCE_EXCERPT})." >&2
    exit 2
fi
if [[ -z "$IDS_RAW" ]]; then
    echo "ERROR: --ids is required (comma-separated credit-request IDs)." >&2
    exit 2
fi

# Normalise comma-separated IDs → JSON array. Reject empty entries from
# "a,,b" or leading/trailing commas so we never send `"requestIds":[""]` to
# the API, which the backend would silently ignore.
IFS=',' read -r -a ID_ARR <<< "$IDS_RAW"
for id in "${ID_ARR[@]}"; do
    # Trim surrounding whitespace defensively.
    id_trimmed="${id#"${id%%[![:space:]]*}"}"
    id_trimmed="${id_trimmed%"${id_trimmed##*[![:space:]]}"}"
    if [[ -z "$id_trimmed" ]]; then
        echo "ERROR: --ids contains an empty entry. Use a comma-separated list with no empty values." >&2
        exit 2
    fi
done

# Build the JSON body via jq so embedded shell metacharacters in IDs (if any
# ever contain them) don't get interpolated into a string-concat body.
body=$(jq -n -c \
    --arg raw "$IDS_RAW" \
    '{
        requestIds: ($raw | split(",") | map(. | gsub("^\\s+|\\s+$"; ""))),
        status: "approved"
     }')

# Make sure the admin script exists before attempting to call it, so the
# error is about missing plumbing rather than "command not found".
if [[ ! -f "$ADMIN_API_SH" ]]; then
    echo "ERROR: muso-admin-api.sh not found at $ADMIN_API_SH — set ADMIN_API_SH env var to override for local tests." >&2
    exit 2
fi

# Invoke muso-admin-api.sh with the flag in its documented position
# (before `call`). DELIBERATELY DO NOT redirect stderr — the whole point of
# this wrapper is that gate rejections and HTTP errors must surface to the
# agent transcript. Capture stdout to classify the outcome.
response=""
rc=0
response=$(bash "$ADMIN_API_SH" \
    --evidence-excerpt "$EVIDENCE_EXCERPT" \
    call PUT /admin/credit-requests "$body") || rc=$?

# Count the IDs actually requested (post-trim) for the stdout summary.
requested=${#ID_ARR[@]}

outcome="unknown"
http_status=""
if [[ $rc -eq 0 ]]; then
    # Response should be a single JSON object from muso-admin-api.sh. Branch
    # on dryRun first (truth floor classifies this as dry_run_intercept) and
    # then on http_status 2xx. Anything else downgrades to http_error even
    # though rc=0 — belt + braces for a future admin-api refactor that
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
    # Non-zero rc: most common cause is gate rejection (return 1 from
    # enforce_credit_approve_gate). It could also be a curl-layer failure
    # (network error, connection refused, etc.) — the admin script's
    # stderr has already printed the human-readable reason. Normalize the
    # exit code to 1 so callers have a stable "something went wrong"
    # signal regardless of the underlying cause (bash, curl, gate).
    outcome="rejected_by_gate"
    rc=1
fi

# Emit the summary line. Authoritative per-ID truth is in .results.jsonl —
# this stdout is just a compact convenience for the caller.
jq -n -c \
    --arg profile_id "$PROFILE_ID" \
    --argjson requested "$requested" \
    --arg outcome "$outcome" \
    --arg http_status "$http_status" \
    '{
        profile_id: $profile_id,
        requested: $requested,
        outcome: $outcome,
        http_status: (if $http_status == "" then null else ($http_status | tonumber? // $http_status) end)
     }'

exit $rc
