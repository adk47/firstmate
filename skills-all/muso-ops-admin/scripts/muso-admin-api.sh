#!/usr/bin/env bash
# muso-admin-api.sh — Core admin API wrapper for all Muso ops skills
# Usage: bash muso-admin-api.sh [--requester email] <command> [options]
#
# Commands:
#   login                              Get/refresh admin JWT token (cached 23h)
#   call <METHOD> <path> [json-body]   Make an authenticated admin API call
#   upload <path> <file> [fields...]   Multipart upload with auth
#   resolve-email <slack_id>           Resolve Slack ID to muso.ai email
#
# Global Options:
#   --requester <email|slack_id>  Email or Slack ID of the human who initiated this action.
#                                 If a Slack ID (U...) is passed, it's resolved to email.
#                                 Sent as 'Requester' header for backend audit trail.
#                                 Also sends 'Service: clio' header.
#
# Requires: MUSO_API_URL, MUSO_ADMIN_EMAIL, MUSO_ADMIN_PASSWORD in env
# Base URL: https://api.muso.ai/api/v3 (routes use /admin/* prefix)

set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required but not found" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# ADMIN_TOKEN_CACHE_PATH override exists so tests can redirect the cache out
# of the production scripts directory; production calls leave it unset and
# get the canonical path next to this script.
TOKEN_CACHE="${ADMIN_TOKEN_CACHE_PATH:-$SCRIPT_DIR/.admin-token-cache}"
TOKEN_MAX_AGE=82800  # 23 hours in seconds
REQUESTER_EMAIL=""   # Set via --requester flag
EVIDENCE_EXCERPT=""  # Set via --evidence-excerpt flag (required for autonomous credit approves)
CONFIRMED_BY=""      # Set via --confirmed-by flag (required for tier-2 writes — see enforce_tier2_approval_gate)
APPROVAL_MSG_ID=""   # Set via --approval-msg-id flag (Slack message ID/ts of the in-thread approval — for audit)

# Tier-2 enforcement state. Persisted to disk so the reverse-direction guard
# fires across separate shell invocations (each agent exec is a new shell).
# /var/log/muso-ops is hydra's canonical location; tests can override with
# MUSO_OPS_STATE_DIR. Created lazily on first write.
MUSO_OPS_STATE_DIR="${MUSO_OPS_STATE_DIR:-/var/log/muso-ops}"
RECENT_MERGES_PATH="${RECENT_MERGES_PATH:-${MUSO_OPS_STATE_DIR}/recent-merges.jsonl}"
TIER2_AUDIT_PATH="${TIER2_AUDIT_PATH:-${MUSO_OPS_STATE_DIR}/tier2-audit.jsonl}"
CREDIT_REJECT_AUDIT_PATH="${CREDIT_REJECT_AUDIT_PATH:-${MUSO_OPS_STATE_DIR}/credit-reject-audit.jsonl}"
TIER2_APPROVERS_PATH="${TIER2_APPROVERS_PATH:-${SCRIPT_DIR}/../config/tier2-approvers.txt}"
TIER2_ENDPOINTS_PATH="${TIER2_ENDPOINTS_PATH:-${SCRIPT_DIR}/../config/tier2-endpoints.txt}"
# Reverse-direction guard window. A second merge that points the OTHER way
# within this many seconds is the 2026-04-29 incident pattern; refuse it.
TIER2_REVERSE_WINDOW_SECS="${TIER2_REVERSE_WINDOW_SECS:-300}"

# --- Bulk destructive-operation gate (incident 2026-05-26) ---
# On 2026-05-26 the ops agent autonomously issued ~285 DELETE
# /admin/track/:id/analytics-sources calls in one run off a vague "fix it",
# wiping the only Spotify analytics link on 10 tracks and collapsing a
# profile's lifetime stream count. This gate caps the blast radius: once
# BULK_DESTRUCTIVE_THRESHOLD destructive DELETEs land within
# BULK_DESTRUCTIVE_WINDOW_SECS, every further destructive DELETE is refused
# unless an explicit second human approval (--confirmed-by + --approval-msg-id)
# is supplied. Requester identity does NOT bypass this gate — the agent
# auto-stamps --requester with whoever is in-thread, so it is not evidence
# that a human reviewed a mass deletion.
BULK_DESTRUCTIVE_PATH="${BULK_DESTRUCTIVE_PATH:-${MUSO_OPS_STATE_DIR}/destructive-ops.jsonl}"
BULK_DESTRUCTIVE_AUDIT_PATH="${BULK_DESTRUCTIVE_AUDIT_PATH:-${MUSO_OPS_STATE_DIR}/bulk-destructive-audit.jsonl}"
BULK_DESTRUCTIVE_THRESHOLD="${BULK_DESTRUCTIVE_THRESHOLD:-10}"
BULK_DESTRUCTIVE_WINDOW_SECS="${BULK_DESTRUCTIVE_WINDOW_SECS:-900}"
BULK_DESTRUCTIVE_EXCLUDE_PATH="${BULK_DESTRUCTIVE_EXCLUDE_PATH:-${SCRIPT_DIR}/../config/bulk-destructive-exclude.txt}"
if ! [[ "$BULK_DESTRUCTIVE_THRESHOLD" =~ ^[1-9][0-9]*$ ]]; then
    echo "FATAL: BULK_DESTRUCTIVE_THRESHOLD must be a positive integer (got '${BULK_DESTRUCTIVE_THRESHOLD}')" >&2
    exit 1
fi
if ! [[ "$BULK_DESTRUCTIVE_WINDOW_SECS" =~ ^[1-9][0-9]*$ ]]; then
    echo "FATAL: BULK_DESTRUCTIVE_WINDOW_SECS must be a positive integer (got '${BULK_DESTRUCTIVE_WINDOW_SECS}')" >&2
    exit 1
fi

# --- Dry-run mode (issue #145) ---
# OPS_DRY_RUN=1 short-circuits every WRITE (anything that isn't GET/HEAD) in
# cmd_call, and all of cmd_upload, with a synthetic 200 response. GET/HEAD
# still hit the real API so the caller can read state. Every would-be write
# is appended to OPS_DRY_RUN_AUDIT_PATH as JSONL for later review. The
# credit-approve gate runs BEFORE the short-circuit so a broken batch still
# fails visibly — the whole point is "what would have happened, gate included".
#
# The method check is fail-closed (deny-list) rather than fail-open
# (PUT|POST|PATCH|DELETE allow-list) — lower-case `put`, typos, and future
# verbs the admin API might add all get intercepted instead of silently
# hitting prod. Only GET/HEAD (case-insensitive) pass through.
case "$(printf %s "${OPS_DRY_RUN:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)        OPS_DRY_RUN=1 ;;
    0|false|no|off|"")    OPS_DRY_RUN=0 ;;
    *)
        # Unrecognized value — treat as false, but warn loudly. Silent
        # fallthrough is the footgun that lets `OPS_DRY_RUN=enable` produce
        # real writes when the user thinks they're in dry-run.
        echo "WARN: OPS_DRY_RUN='${OPS_DRY_RUN}' not recognized; treating as false. Use 1|true|yes|on to enable." >&2
        OPS_DRY_RUN=0
        ;;
esac
OPS_DRY_RUN_AUDIT_PATH="${OPS_DRY_RUN_AUDIT_PATH:-/tmp/ops-dry-run-audit.jsonl}"
# Tracks whether the last write_dry_run_audit call succeeded. Read by
# emit_dry_run_response to surface audit failure in the synthetic envelope.
DRY_RUN_AUDIT_FAILED=0

is_dry_run_mode() {
    [[ "$OPS_DRY_RUN" == "1" ]]
}

# Append a JSONL audit line for a would-be write. Uses jq -n for consistency
# with runlog.sh / compute-run-summary.sh; arg-passing avoids shell
# interpolation of the body entirely. On any failure to write, emits a loud
# stderr warning and sets DRY_RUN_AUDIT_FAILED=1 — callers (emit_dry_run_response)
# surface that flag so the caller never mistakes "audit lost" for "audited".
write_dry_run_audit() {
    local method="$1" path="$2" body="${3:-}" kind="${4:-call}"
    local audit_dir ts run_id
    audit_dir="$(dirname "$OPS_DRY_RUN_AUDIT_PATH")"
    if ! mkdir -p "$audit_dir" 2>/dev/null; then
        echo "WARN: could not create audit dir ${audit_dir}; dry-run audit line LOST for ${method} ${path}" >&2
        DRY_RUN_AUDIT_FAILED=1
        return 0
    fi
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    run_id="${OPS_RUN_ID:-${RUN_ID:-}}"
    # Filesystem fallback (issue #152). SKILL.md B0c sets OPS_RUN_ID in its
    # shell, but every subsequent exec tool call is a fresh shell — the export
    # doesn't propagate, so audit lines from per-call bash blocks would land
    # with run_id=null even though a run is active. Read OPS_RUNLOG_DIR/
    # latest.txt (written by runlog.sh init) as the filesystem source of truth
    # and extract the run_id from its filename. Only accept a filename that
    # matches the canonical run_id shape to avoid stuffing garbage into the
    # audit trail if latest.txt ever gets clobbered.
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
    # Upload kind stores the local file path in its own field; call kind puts
    # the JSON body string in body. This disambiguates uploads vs JSON writes
    # for post-run review — a path in `body` would otherwise look malformed.
    local body_arg file_path_arg
    if [[ "$kind" == "upload" ]]; then
        body_arg=""
        file_path_arg="$body"
    else
        body_arg="$body"
        file_path_arg=""
    fi
    local line
    if ! line=$(jq -n -c \
        --arg ts "$ts" \
        --arg kind "$kind" \
        --arg method "$method" \
        --arg path "$path" \
        --arg body "$body_arg" \
        --arg file_path "$file_path_arg" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg run_id "$run_id" \
        '{
            ts:$ts, kind:$kind, method:$method, path:$path,
            body:      (if $body      == "" then null else $body      end),
            file_path: (if $file_path == "" then null else $file_path end),
            requester: (if $requester == "" then null else $requester end),
            run_id:    (if $run_id    == "" then null else $run_id    end)
         }' 2>/dev/null); then
        echo "WARN: jq failed to build audit line; dry-run audit LOST for ${method} ${path}" >&2
        DRY_RUN_AUDIT_FAILED=1
        return 0
    fi
    if ! printf '%s\n' "$line" >> "$OPS_DRY_RUN_AUDIT_PATH" 2>/dev/null; then
        echo "WARN: could not append to ${OPS_DRY_RUN_AUDIT_PATH}; dry-run audit LOST for ${method} ${path}" >&2
        DRY_RUN_AUDIT_FAILED=1
        return 0
    fi
}

# Synthetic response used for every intercepted write. body is null (NOT a
# stand-in {ok:true} payload) so consumers that expect real-API shape —
# .body.items, .body.data.id — fail loudly instead of silently reading null
# from a lying stand-in. The top-level `dryRun` key is the authoritative
# branch signal. dryRun_audit_failed surfaces lost audit lines so callers
# can detect them in the same envelope.
emit_dry_run_response() {
    local audit_failed="${DRY_RUN_AUDIT_FAILED:-0}"
    if [[ "$audit_failed" == "1" ]]; then
        printf '%s\n' '{"http_status":200,"dryRun":true,"dryRun_audit_failed":true,"body":null,"wouldHaveExecuted":true}'
    else
        printf '%s\n' '{"http_status":200,"dryRun":true,"body":null,"wouldHaveExecuted":true}'
    fi
}

# --- Slack ID → Email mapping ---
# Maps Slack user IDs to muso.ai emails for the Requester header.
# The backend uses this to know which human initiated admin actions.
# Using case statement (bash 3.2 on macOS doesn't support declare -A).

resolve_slack_to_email() {
    local input="$1"
    # If it already looks like an email, return as-is
    if [[ "$input" == *@* ]]; then
        echo "$input"
        return 0
    fi
    # Resolve Slack ID to email
    case "$input" in
        U7RP6HKUZ)  echo "aaron@muso.ai" ;;
        U03TYGJF1N3) echo "serhii@muso.ai" ;;
        U038BM16T7W) echo "jan@muso.ai" ;;
        U02S7TJ7QHY) echo "oleg@muso.ai" ;;
        U0AL36NADEY) echo "nick@muso.ai" ;;
        U0A8CCTTAAG) echo "liza@muso.ai" ;;
        *)
            # Unknown Slack ID — return as-is
            echo "$input"
            return 1
            ;;
    esac
    return 0
}

# --- Helpers ---

die() { echo "ERROR: $*" >&2; exit 1; }

check_env() {
    [[ -n "${MUSO_API_URL:-}" ]] || die "MUSO_API_URL not set"
    [[ -n "${MUSO_ADMIN_EMAIL:-}" ]] || die "MUSO_ADMIN_EMAIL not set"
    [[ -n "${MUSO_ADMIN_PASSWORD:-}" ]] || die "MUSO_ADMIN_PASSWORD not set"
}

get_token() {
    # Return cached token if fresh
    if [[ -f "$TOKEN_CACHE" ]]; then
        local cached_time
        cached_time=$(head -1 "$TOKEN_CACHE")
        local now
        now=$(date +%s)
        if (( now - cached_time < TOKEN_MAX_AGE )); then
            tail -1 "$TOKEN_CACHE"
            return 0
        fi
    fi

    # Login and cache
    local resp
    resp=$(curl -sf -X POST "${MUSO_API_URL}/admin/user/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${MUSO_ADMIN_EMAIL}\",\"password\":\"${MUSO_ADMIN_PASSWORD}\"}" 2>&1) \
        || die "Login failed: $resp"

    local token
    token=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('authentication',{}).get('accessToken','') or d.get('data',{}).get('user',{}).get('accessToken','') or d.get('token',''))")
    [[ -n "$token" ]] || die "No token in login response"

    echo "$(date +%s)" > "$TOKEN_CACHE"
    echo "$token" >> "$TOKEN_CACHE"
    chmod 600 "$TOKEN_CACHE"
    echo "$token"
}

# --- Commands ---

cmd_login() {
    check_env
    local token
    token=$(get_token)
    echo "OK: Token acquired (${#token} chars). Cached at $TOKEN_CACHE"
}

# --- Credit approve gate (deterministic, session-log-based) ---
# Blocks autonomous PUT /admin/credit-requests status=approved unless the active
# openclaw session log shows >=CV_REQUIRED_LOADS distinct Tier 1 pages that were:
#   (a) loaded via the `browser` tool (NOT web_fetch/web_search/anything else), and
#   (b) whose `toolResult.content[0].text` contains --evidence-excerpt as a
#       literal substring (case-insensitive).
# Bypassed for human-initiated approves (--requester set to non-clio identity).
#
# This exists because openclaw's before_tool_call plugin hook does NOT fire
# reliably on exec calls in YOLO mode (tools.exec.security=full, ask=off).
# The bash layer sees 100% of admin API traffic; plugins do not.

# Hosts that count toward the >=CV_REQUIRED_LOADS browse-quorum for an approve.
# Must match lib/browser-evidence.sh:67 in muso-ops-credit-verification — the
# dispatcher already filters by that regex, so this gate is a backstop and
# strictly cannot count more hosts than the dispatcher does.
CV_TIER1_HOSTS='music\.apple\.com|musicbrainz\.org|discogs\.com|allmusic\.com'
# Hosts where web_fetch is JS-shell-only and substituting it for browser
# always produces empty/wrong evidence — every Tier-1 web_fetch refuses the
# approve. Superset of CV_TIER1_HOSTS: Tidal's track/album SPAs are also
# JS-rendered, even though Tidal is Tier-2 for the browse-quorum (it's only
# used as a backend album-credits URL, not as a free-form quorum host).
CV_TIER1_WEBFETCH_BLOCKED='music\.apple\.com|musicbrainz\.org|discogs\.com|allmusic\.com|tidal\.com'
CV_REQUIRED_LOADS="${CV_REQUIRED_LOADS:-2}"
if ! [[ "$CV_REQUIRED_LOADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "FATAL: CV_REQUIRED_LOADS must be a positive integer (got '${CV_REQUIRED_LOADS}')" >&2
    exit 1
fi
CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"
CV_EVIDENCE_EXCERPT_MIN="${CV_EVIDENCE_EXCERPT_MIN:-8}"
CV_EVIDENCE_EXCERPT_MAX="${CV_EVIDENCE_EXCERPT_MAX:-200}"

enforce_credit_approve_gate() {
    local method="$1" path="$2" body="$3"

    # Gate covers PUT (batch approve: PUT /admin/credit-requests with
    # "requestIds":[...]) AND PATCH (single-credit approve: PATCH
    # /admin/credit-requests/<id>). The 2026-04-22 live dry-run test showed
    # the bot using PATCH for every individual approve, which under the old
    # PUT-only check bypassed the browser-evidence gate entirely. Normalize
    # method case defensively: `patch` / `Patch` must gate the same as `PATCH`.
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    case "$method_uc" in
        PUT|PATCH) ;;
        *) return 0 ;;
    esac
    # Match both /admin/credit-requests and /admin/credit-requests/<id>
    [[ "$path" == /admin/credit-requests* ]] || return 0
    echo "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"approved"' || return 0

    # Human override for per-credit verification: allow ONLY when --requester
    # resolves to Jan or Aaron — the humans authorized to approve individual
    # credits after reviewing them in an escalation thread. Other identities
    # (Nick triggering a batch, etc.) do NOT constitute per-credit verification.
    # The agent should NOT pass --requester on autonomous batch approves.
    case "${REQUESTER_EMAIL:-}" in
        jan@muso.ai|aaron@muso.ai)
            return 0
            ;;
    esac

    # Allow opt-out for explicitly non-CV admin scripts that need to approve credits
    # (currently none — placeholder for future).
    if [[ "${CV_APPROVE_GATE_DISABLED:-0}" == "1" ]]; then
        return 0
    fi

    # --evidence-excerpt is MANDATORY for autonomous approves. Missing or too-short
    # excerpts fail fast so the agent gets a clear "what to do" message.
    local excerpt="${EVIDENCE_EXCERPT:-}"
    if [[ -z "$excerpt" ]]; then
        cat >&2 <<EOF
credit_approve_gate: --evidence-excerpt is required for autonomous approves.
Both verbs are gated:
    # Batch (PUT):
    muso-admin-api.sh --evidence-excerpt "<literal substring>" \\
        call PUT /admin/credit-requests '{"requestIds":["<cr_id>"],"status":"approved"}'
    # Single credit (PATCH):
    muso-admin-api.sh --evidence-excerpt "<literal substring>" \\
        call PATCH /admin/credit-requests/<cr_id> '{"status":"approved"}'
The excerpt must be a short substring (>=${CV_EVIDENCE_EXCERPT_MIN} chars) that literally appears on >=${CV_REQUIRED_LOADS} distinct Tier 1 pages you loaded via the \`browser\` tool in this session. Good examples: the artist's name as rendered on MusicBrainz, the role string as it appears on AllMusic credits, a track title as it appears on Apple Music or Discogs.
EOF
        return 1
    fi
    if (( ${#excerpt} < CV_EVIDENCE_EXCERPT_MIN )); then
        echo "credit_approve_gate: --evidence-excerpt must be >=${CV_EVIDENCE_EXCERPT_MIN} chars (got ${#excerpt}). Use a more specific substring." >&2
        return 1
    fi
    if (( ${#excerpt} > CV_EVIDENCE_EXCERPT_MAX )); then
        echo "credit_approve_gate: --evidence-excerpt must be <=${CV_EVIDENCE_EXCERPT_MAX} chars (got ${#excerpt}). Use a shorter substring." >&2
        return 1
    fi

    # Locate the most-recently modified openclaw session log (any profile).
    # Portable across GNU/BSD: find filters by age; stat resolves mtime for sort.
    local session_log
    session_log=$(
        find /root/.openclaw-main/agents \
            -maxdepth 3 -type f -name "*.jsonl" -mmin "-${CV_SESSION_MAX_AGE_MIN}" 2>/dev/null \
        | while IFS= read -r f; do
            mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
            [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
          done \
        | sort -rn | head -1 | cut -d' ' -f2-
    )
    if [[ -z "$session_log" ]]; then
        echo "credit_approve_gate: no active openclaw session log (mtime <${CV_SESSION_MAX_AGE_MIN} min) found; refusing autonomous approve." >&2
        return 1
    fi

    # Tier 1 substitution block: Tier 1 hosts are JS-rendered. Using
    # web_fetch on them returns the non-rendered HTML, which is a different
    # (and often wrong) data surface than what the browser tool sees.
    # Multiple real incidents (2026-04-16, 2026-04-20, 2026-04-22) featured
    # web_fetch substituting for browser on these hosts. Primary defense is
    # that web_fetch is in the operations agent's toolDenyList in
    # openclaw-main.json. This is the backstop — if the tool deny is ever
    # removed or misconfigured, the approve still refuses. Also catches
    # sessions run from agents whose toolDenyList we don't control.
    local tier1_webfetch_hosts
    tier1_webfetch_hosts=$(
        jq -R -r -n \
            --arg hosts "$CV_TIER1_WEBFETCH_BLOCKED" '
            ($hosts | split("|") | map(gsub("\\\\."; ".")) | map({(.): true}) | add) as $t1
            |
            [inputs | fromjson? // empty | select(type == "object")] as $lines
            |
            [
                $lines[]
                | .message?.content[]? // empty
                | select(.type == "toolCall" and .name == "web_fetch")
                | (.arguments.url // "") | select(. != "")
                | capture("^https?://(?:www\\.)?(?<host>[^/]+)").host
                | select($t1[.] // false)
            ]
            | unique | .[]
        ' "$session_log" 2>/dev/null | tr '\n' ',' | sed 's/,$//'
    )
    if [[ -n "$tier1_webfetch_hosts" ]]; then
        cat >&2 <<EOF
credit_approve_gate: web_fetch call(s) to Tier 1 host(s) detected in this session: ${tier1_webfetch_hosts}.
Tier 1 pages (Apple Music / MusicBrainz / Discogs / AllMusic / Tidal)
are JS-rendered — web_fetch returns the raw HTML shell, not the data the
browser tool sees. Every Tier 1 load for credit verification MUST go through
the \`browser\` tool. Reload the relevant page(s) via \`browser\` and retry.
(This check is a backstop — web_fetch should not even be callable; if you
reached this error, something is misconfigured upstream.)
EOF
        return 1
    fi

    # Content-matched evidence count. Forward scan:
    #  1. Track toolCall blocks (tool_use): record toolCallId -> {name, url}
    #  2. On toolResult blocks: if the toolCall was `browser` AND its URL is
    #     Tier 1 AND the toolResult.content text contains --evidence-excerpt
    #     (case-insensitive), count the URL's HOSTNAME as "grounded evidence".
    # Distinct HOSTNAMES required, not distinct URLs — two loads of
    # musicbrainz.org still count as 1 toward the bar.
    # Per-approve freshness is enforced by the excerpt changing per cr_id:
    # different credit → different artist/role → different excerpt string →
    # different browser results required. No reset-on-approve marker needed
    # (and real session logs escape those markers inside JSON strings anyway).
    local count
    count=$(
        jq -R -r -n \
            --arg excerpt "$(echo "$excerpt" | tr '[:upper:]' '[:lower:]')" \
            --arg hosts "$CV_TIER1_HOSTS" \
        '
        # Build tier-1 host lookup: unescape "\." -> ".", index as object keys
        ($hosts | split("|") | map(gsub("\\\\."; ".")) | map({(.): true}) | add) as $t1
        |
        # Slurp all JSONL lines as raw text (-R), parse each, skip malformed
        [inputs | fromjson? // empty | select(type == "object")] as $lines
        |
        # Index toolCall entries: id -> {name, url}
        (reduce ($lines[] | .message.content[]? | select(.type == "toolCall")) as $tc
            ({}; . + {($tc.id): {name: $tc.name, url: $tc.arguments.url}})
        ) as $calls
        |
        # Scan toolResult entries, join via toolCallId, filter, dedup
        [
            $lines[]
            | .message | select(.role == "toolResult")
            | . as $tr
            | $calls[.toolCallId] // empty
            | select(.name == "browser")
            | (.url // "") | select(. != "")
            | capture("^https?://(?:www\\.)?(?<host>[^/]+)").host
            | select($t1[.] // false)
            | . as $host
            | $tr.content
            | map(.text // "") | join(" ") | ascii_downcase
            | select(contains($excerpt))
            | $host
        ]
        | unique | length
        ' "$session_log" 2>/dev/null || echo 0
    )
    count="${count:-0}"

    if (( count < CV_REQUIRED_LOADS )); then
        cat >&2 <<EOF
credit_approve_gate: insufficient grounded evidence — found ${count}/${CV_REQUIRED_LOADS} distinct Tier 1 pages where --evidence-excerpt "${excerpt}" appears in the browser result.
Requirements:
  * Load >=${CV_REQUIRED_LOADS} DIFFERENT Tier 1 hostnames via the \`browser\` tool
    (music.apple.com, musicbrainz.org, discogs.com, allmusic.com).
  * Each browser result must literally contain the excerpt string.
  * web_fetch / web_search loads do NOT count. Use \`browser\` only.
If the excerpt is too broad or too narrow, try one that appears verbatim in the
rendered page text (e.g. the artist name as shown on MusicBrainz, or a role
string as rendered on AllMusic credits).
If Tier 1 pages genuinely don't confirm the credit, downgrade the verdict to
UNVERIFIABLE — NEEDS REVIEW and escalate to Jan (<@U038BM16T7W>).
Session log checked: ${session_log}
EOF
        return 1
    fi

    return 0
}

# --- Credit reject gate (incident 2026-07-22) ---
# Rejection of a credit request is NEVER autonomous. core-backend's
# updateStatus.js transition matrix has no rejected->user_verification_needed
# path (the only exit from `rejected` is `approved`), so an agent mistake is
# irreversible for the customer's verification flow: on 2026-07-22 the Ops
# agent rejected 28 UVN requests during Jan's ClickUp sweep and Jan's "move
# them back to verification needed" correction silently no-oped (hollow 200).
# Doctrine now matches the customer-facing rule (Caroline never rejects):
# approve, or keep in user_verification_needed and ask for more proof. A hard
# reject requires an explicit per-batch human decision, evidenced the same way
# as bulk-destructive DELETEs: --confirmed-by <tier-2 approver> +
# --approval-msg-id. Deliberately NO env off-switch and NO dry-run skip — the
# actor this gate restrains controls its own env, and a dry-run preview of an
# unauthorized reject should fail loudly too.
enforce_credit_reject_gate() {
    local method="$1" path="$2" body="$3"

    # Same verb/path detection style as enforce_credit_approve_gate: both PUT
    # (bulk, collection endpoint) and PATCH (single credit) are gated.
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    case "$method_uc" in
        PUT|PATCH) ;;
        *) return 0 ;;
    esac
    [[ "$path" == /admin/credit-requests* ]] || return 0
    # Detect the reject STRUCTURALLY, the way core-backend's JSON.parse does —
    # not by literal bytes. A body that parses to status:"rejected" via a \uXXXX
    # escape or an inter-token newline slips a line-oriented literal grep, yet
    # the backend still honors it (and reject is a ONE-WAY DOOR). jq normalizes
    # both; the literal grep is kept as a belt-and-suspenders backstop for any
    # jq/JSON.parse divergence. Gate if EITHER sees a reject — never less than
    # the old grep-only behavior.
    local status_val
    status_val="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)"
    if [[ "$status_val" != "rejected" ]] \
        && ! echo "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"rejected"'; then
        return 0
    fi

    # Requester identity is auto-stamped from whoever is in-thread — it is not
    # evidence a human decided to reject, so it does NOT bypass this gate.
    if [[ -z "$CONFIRMED_BY" ]]; then
        cat >&2 <<EOF
MUSO_CREDIT_REJECT_APPROVAL_REQUIRED: ${method} ${path} would set credit-request status=rejected.
Rejection is a one-way door: the backend has no rejected->user_verification_needed
transition (only rejected->approved), so a wrong reject cannot be undone.
Do NOT reject autonomously. Instead:
  * leave the request in user_verification_needed and ask for more proof, or
  * escalate to Jan (<@U038BM16T7W>) in-thread with your evidence and rationale.
A hard reject requires an explicit human decision:
  bash $0 --requester <slack_id> --confirmed-by <jan|aaron|nick> --approval-msg-id <slack_ts> \\
    call ${method} "${path}" '<body>'
EOF
        return 1
    fi

    if ! is_tier2_approver "$CONFIRMED_BY"; then
        cat >&2 <<EOF
MUSO_CREDIT_REJECT_APPROVAL_INVALID: --confirmed-by '${CONFIRMED_BY}' is not in the approver allowlist.
Allowed approvers (from $TIER2_APPROVERS_PATH):
$(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | sed 's/^/  - /' || echo "  (file missing)")
EOF
        return 1
    fi

    if [[ -z "$APPROVAL_MSG_ID" ]]; then
        echo "MUSO_CREDIT_REJECT_APPROVAL_REQUIRED: --approval-msg-id <slack_msg_ts> is required alongside --confirmed-by for credit-request rejections (audit trail)." >&2
        return 1
    fi

    # Audit BEFORE allowing — fail-closed, same rationale as the tier-2 gate:
    # "rejected, no record of who decided it" is worse than a retryable error.
    if ! mkdir -p "$(dirname "$CREDIT_REJECT_AUDIT_PATH")" 2>/dev/null; then
        echo "MUSO_CREDIT_REJECT_AUDIT_UNWRITABLE: cannot create $(dirname "$CREDIT_REJECT_AUDIT_PATH") — refusing the reject to preserve the audit trail." >&2
        return 1
    fi
    local ts audit_rc=0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n -c \
        --arg ts "$ts" \
        --arg method "$method" \
        --arg path "$path" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg confirmed_by "$CONFIRMED_BY" \
        --arg approval_msg_id "$APPROVAL_MSG_ID" \
        '{ts:$ts, gate:"credit_reject", method:$method, path:$path, requester:$requester, confirmed_by:$confirmed_by, approval_msg_id:$approval_msg_id}' \
        >> "$CREDIT_REJECT_AUDIT_PATH" || audit_rc=$?
    if (( audit_rc != 0 )); then
        echo "MUSO_CREDIT_REJECT_AUDIT_UNWRITABLE: append to $CREDIT_REJECT_AUDIT_PATH failed (rc=$audit_rc) — refusing the reject to preserve the audit trail." >&2
        return 1
    fi
    return 0
}

# --- Tier-2 approval gate (incident 2026-04-29) ---
# Tier 2 = high-blast-radius admin writes that require Aaron's explicit
# in-thread approval before the agent may execute. The gate refuses to issue
# the call unless --confirmed-by matches the approver allowlist AND
# --approval-msg-id is set (so the audit trail can point back to the exact
# Slack message that authorized the action).
#
# Endpoints in scope are loaded from $TIER2_ENDPOINTS_PATH (one METHOD PATH
# per line, '#' comments allowed). Approvers from $TIER2_APPROVERS_PATH (one
# handle per line). If either file is missing, the gate fails CLOSED on
# tier-2 writes — never silently allow.
#
# Dry-run mode skips the gate entirely (dry-runs don't mutate prod, so
# requiring approval would just block local debugging).

is_tier2_endpoint() {
    local method="$1" path="$2"
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    # Strip any query string before matching (mirror is_bulk_destructive_op).
    path="${path%%\?*}"
    [[ -f "$TIER2_ENDPOINTS_PATH" ]] || return 1
    # Each line: "METHOD /path" with leading '#' for comments. A ":param"
    # segment in an entry matches EXACTLY ONE path segment, so
    # "DELETE /admin/user/:id" gates "/admin/user/123" but NOT the sub-resource
    # "/admin/user/123/image" — over-matching there would wrongly gate e.g. the
    # credit-removal endpoint /admin/track/:id/profile/:pid/credits and break
    # remove_credits. Param-less entries (the merge endpoints) stay EXACT
    # string matches.
    local restore_extglob=0
    shopt -q extglob || { shopt -s extglob; restore_extglob=1; }
    local rc=1
    while IFS= read -r line; do
        line="${line%%#*}"  # strip comment
        line="${line## }"
        line="${line%% }"
        [[ -z "$line" ]] && continue
        local m p pattern
        m="$(printf %s "$line" | awk '{print $1}' | tr '[:lower:]' '[:upper:]')"
        p="$(printf %s "$line" | awk '{print $2}')"
        [[ "$m" == "$method_uc" ]] || continue
        # ":word" -> one non-slash segment; literal entries are left unchanged.
        pattern="$(printf %s "$p" | sed -E 's#:[A-Za-z_][A-Za-z0-9_]*#+([!/])#g')"
        # shellcheck disable=SC2053  # RHS unquoted so the extglob pattern is active.
        if [[ "$path" == $pattern ]]; then
            rc=0
            break
        fi
    done < "$TIER2_ENDPOINTS_PATH"
    (( restore_extglob )) && shopt -u extglob
    return "$rc"
}

is_tier2_approver() {
    local handle="$1"
    [[ -n "$handle" ]] || return 1
    [[ -f "$TIER2_APPROVERS_PATH" ]] || return 1
    local handle_lc
    handle_lc="$(printf %s "$handle" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line## }"
        line="${line%% }"
        [[ -z "$line" ]] && continue
        local approver_lc
        approver_lc="$(printf %s "$line" | tr '[:upper:]' '[:lower:]')"
        [[ "$handle_lc" == "$approver_lc" ]] && return 0
    done < "$TIER2_APPROVERS_PATH"
    return 1
}

enforce_tier2_approval_gate() {
    local method="$1" path="$2"

    # Fail-closed if the endpoint allowlist file is missing. Without it,
    # is_tier2_endpoint cannot decide scope and would silently pass every
    # call through. The file ships in the repo (config/tier2-endpoints.txt);
    # absence here means a packaging or rsync regression.
    if [[ ! -f "$TIER2_ENDPOINTS_PATH" ]]; then
        echo "MUSO_TIER2_CONFIG_MISSING: TIER2_ENDPOINTS_PATH (${TIER2_ENDPOINTS_PATH}) is missing — refusing every write until the tier-2 allowlist is restored." >&2
        return 1
    fi

    # Only fire on tier-2 writes. Non-tier-2 paths and reads pass through.
    is_tier2_endpoint "$method" "$path" || return 0

    # Dry-run: skip — synthetic response, no prod mutation.
    if is_dry_run_mode; then
        return 0
    fi

    if [[ -z "$CONFIRMED_BY" ]]; then
        cat >&2 <<EOF
MUSO_TIER2_APPROVAL_REQUIRED: ${method} ${path} is a tier-2 admin write.
Pass --confirmed-by <handle> with explicit in-thread approval from one of:
$(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | sed 's/^/  - /' || echo "  (approver allowlist file missing: ${TIER2_APPROVERS_PATH})")

Also pass --approval-msg-id <slack_msg_ts> so the audit trail can link back to the approval.

Example:
  bash $0 --requester <slack_id> --confirmed-by aaron --approval-msg-id 1777474838.796239 \\
    call ${method} "${path}" '<body>'

This gate exists because of incident 2026-04-29 (profile merge). See muso-ops-profiles/SKILL.md "Merge Profiles" stop-rule.
EOF
        return 1
    fi

    if ! is_tier2_approver "$CONFIRMED_BY"; then
        cat >&2 <<EOF
MUSO_TIER2_APPROVAL_INVALID: --confirmed-by '${CONFIRMED_BY}' is not in the tier-2 approver allowlist.
Allowed approvers (from $TIER2_APPROVERS_PATH):
$(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | sed 's/^/  - /' || echo "  (file missing)")
EOF
        return 1
    fi

    if [[ -z "$APPROVAL_MSG_ID" ]]; then
        echo "MUSO_TIER2_APPROVAL_REQUIRED: --approval-msg-id <slack_msg_ts> is required alongside --confirmed-by for tier-2 writes (audit trail)." >&2
        return 1
    fi

    # Audit the approval BEFORE executing. Fail-closed if we can't write —
    # the audit trail is the entire authorization story for tier-2 writes
    # and "merge applied, no record of who approved it" is a worse failure
    # mode than "operator gets a clear error and retries after fixing disk".
    if ! mkdir -p "$(dirname "$TIER2_AUDIT_PATH")" 2>/dev/null; then
        echo "MUSO_TIER2_AUDIT_UNWRITABLE: cannot create $(dirname "$TIER2_AUDIT_PATH") — refusing tier-2 write to preserve audit trail. Fix the directory permissions and retry." >&2
        return 1
    fi
    local ts audit_rc=0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n -c \
        --arg ts "$ts" \
        --arg method "$method" \
        --arg path "$path" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg confirmed_by "$CONFIRMED_BY" \
        --arg approval_msg_id "$APPROVAL_MSG_ID" \
        '{ts:$ts, method:$method, path:$path, requester:$requester, confirmed_by:$confirmed_by, approval_msg_id:$approval_msg_id}' \
        >> "$TIER2_AUDIT_PATH" || audit_rc=$?
    if (( audit_rc != 0 )); then
        echo "MUSO_TIER2_AUDIT_UNWRITABLE: append to $TIER2_AUDIT_PATH failed (rc=$audit_rc) — refusing tier-2 write to preserve audit trail." >&2
        return 1
    fi
    return 0
}

# --- Reverse-direction guard for /admin/profiles/merge (incident 2026-04-29) ---
# Refuses to issue a merge whose mergeInto appears in any recent profilesIds[]
# (or whose profilesIds[] intersects any recent mergeInto) within
# TIER2_REVERSE_WINDOW_SECS. This is the call pattern that destroyed prod state
# on 2026-04-29: agent issued mergeInto=A profilesIds=[B], thought it failed,
# then issued mergeInto=B profilesIds=[A] to "test the reverse direction" —
# which moved A's claim/workspace/playlist onto B.

merge_body_extract_ids() {
    # Stdin: JSON body. Stdout: two lines — "INTO=<id>" then "IDS=<id1,id2,...>".
    # Returns 0 if both fields parsed, 1 otherwise.
    local body="$1"
    local into ids
    into=$(printf '%s' "$body" | jq -r '.mergeInto // empty' 2>/dev/null) || return 1
    ids=$(printf '%s' "$body" | jq -r '(.profilesIds // []) | join(",")' 2>/dev/null) || return 1
    [[ -n "$into" && -n "$ids" ]] || return 1
    printf 'INTO=%s\nIDS=%s\n' "$into" "$ids"
}

enforce_merge_reverse_direction_guard() {
    local method="$1" path="$2" body="$3"

    [[ "$path" == "/admin/profiles/merge" ]] || return 0
    is_dry_run_mode && return 0

    # Malformed body on a tier-2 merge is a fail-closed condition. The
    # backend's own input validation may tolerate shapes the guard can't
    # parse — we'd rather refuse here than skip the reverse-direction
    # check on a valid-but-unparseable-by-us body.
    local extracted into ids
    if ! extracted=$(merge_body_extract_ids "$body"); then
        echo "MUSO_MERGE_BODY_UNPARSEABLE: refusing /admin/profiles/merge — body did not parse as {mergeInto: <id>, profilesIds: [<id>, ...]}." >&2
        return 1
    fi
    into=$(printf '%s' "$extracted" | sed -n 's/^INTO=//p')
    ids=$(printf '%s' "$extracted" | sed -n 's/^IDS=//p')

    # First run: state file doesn't exist yet, so there's nothing to
    # compare against. This is the only case we let pass — record_merge_call
    # will create the file on the first 2xx.
    [[ -f "$RECENT_MERGES_PATH" ]] || return 0

    # Window cutoff in epoch seconds. `date +%s` is POSIX and portable
    # (works on both BSD and GNU); subtraction is just bash arithmetic.
    local cutoff_epoch=$(( $(date +%s) - TIER2_REVERSE_WINDOW_SECS ))

    # Find any recent entry where:
    #   (a) the new mergeInto matches an old profilesIds entry, OR
    #   (b) any new profilesIds entry matches an old mergeInto.
    local conflict
    conflict=$(
        jq -R -r -n \
            --arg into "$into" \
            --arg ids_csv "$ids" \
            --argjson cutoff "$cutoff_epoch" \
        '
        ($ids_csv | split(",")) as $new_ids
        |
        [inputs | fromjson? // empty | select(type == "object")]
        | map(select((.epoch // 0) >= $cutoff))
        | map(. as $entry | select(
              (($entry.profilesIds // []) | index($into))
              or
              ([$entry.mergeInto // ""] | inside($new_ids))
              or
              ($new_ids | any(. as $i | ($entry.profilesIds // []) | index($i)))
          ))
        | .[0] // empty
        | tojson
        ' "$RECENT_MERGES_PATH" 2>/dev/null
    )

    if [[ -n "$conflict" ]]; then
        cat >&2 <<EOF
MUSO_MERGE_OVERLAPPING_IDS_BLOCKED: refusing /admin/profiles/merge.

A recent merge (within ${TIER2_REVERSE_WINDOW_SECS}s) has overlapping IDs with this call:
  new: mergeInto=${into}, profilesIds=[${ids}]
  prior conflicting entry: ${conflict}

The guard fires on either of these patterns:
  - Reverse direction (mergeInto/profilesIds swapped) — the call shape that
    caused production damage on 2026-04-29 (workspace/claim/playlist moved
    off the intended survivor).
  - Same-direction retry after the prior call completed — the prior merge
    may not yet be fully observable (async industry pipeline), and re-issuing
    is rarely the correct answer.

In both cases: do NOT retry, do NOT flip the direction. See muso-ops-profiles/SKILL.md "Merge Profiles" STOP-rule. Escalate to Aaron in the same Slack thread and wait.

If you genuinely need to issue this call (e.g. legitimate corrective merge after a wait), you must:
  1. Wait until ${TIER2_REVERSE_WINDOW_SECS}s have passed since the prior merge, OR
  2. Manually clear the relevant entries from ${RECENT_MERGES_PATH} after explicit Aaron approval.
EOF
        return 1
    fi
    return 0
}

record_merge_call() {
    local method="$1" path="$2" body="$3" http_code="$4"
    [[ "$path" == "/admin/profiles/merge" ]] || return 0
    # Match any 2xx — the backend currently returns 200, but a future
    # contract change to 201/204 would otherwise leave the merge unrecorded
    # and silently disable the reverse-direction guard for the next call.
    [[ "$http_code" =~ ^2[0-9][0-9]$ ]] || return 0
    is_dry_run_mode && return 0

    local extracted into ids_csv
    extracted=$(merge_body_extract_ids "$body") || return 0
    into=$(printf '%s' "$extracted" | sed -n 's/^INTO=//p')
    ids_csv=$(printf '%s' "$extracted" | sed -n 's/^IDS=//p')

    mkdir -p "$(dirname "$RECENT_MERGES_PATH")" 2>/dev/null || return 0
    local epoch ts
    epoch=$(date +%s)
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n -c \
        --arg ts "$ts" \
        --argjson epoch "$epoch" \
        --arg method "$method" \
        --arg path "$path" \
        --arg mergeInto "$into" \
        --arg ids_csv "$ids_csv" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg confirmed_by "$CONFIRMED_BY" \
        --arg approval_msg_id "$APPROVAL_MSG_ID" \
        '{
            ts:$ts, epoch:$epoch, method:$method, path:$path,
            mergeInto:$mergeInto,
            profilesIds:($ids_csv | split(",")),
            requester:$requester,
            confirmed_by:$confirmed_by,
            approval_msg_id:$approval_msg_id
        }' \
        >> "$RECENT_MERGES_PATH" 2>/dev/null || true
}

# --- Bulk destructive-operation gate helpers (incident 2026-05-26) ---

# is_bulk_destructive_op METHOD PATH -> 0 if this call counts toward the
# destructive-delete budget, 1 if it should be ignored.
#
# Scope: the DELETE verb only. POSTs are excluded by design — claim
# reject/revert run 50+ per legitimate fraud sweep, and merge/unmerge are
# already tier-2 gated per-call. A small DENY-LIST of harmless/regenerable
# DELETE path globs is excluded (see $BULK_DESTRUCTIVE_EXCLUDE_PATH).
#
# Deliberately FAIL-OPEN-TO-COUNTING: a missing exclude file means EVERYTHING
# counts. This is the opposite of is_tier2_endpoint (which fails closed-to-not-
# tier2) and is intentional — the 2026-05-26 incident was an endpoint on no
# list at all, so the safe default here is "count it".
is_bulk_destructive_op() {
    local method="$1" path="$2"
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    [[ "$method_uc" == "DELETE" ]] || return 1
    # Strip any query string before matching the deny-list globs.
    path="${path%%\?*}"
    if [[ -f "$BULK_DESTRUCTIVE_EXCLUDE_PATH" ]]; then
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line## }"
            line="${line%% }"
            [[ -z "$line" ]] && continue
            # Glob match: RHS intentionally unquoted so `*` is active.
            # shellcheck disable=SC2053
            if [[ "$path" == $line ]]; then
                return 1
            fi
        done < "$BULK_DESTRUCTIVE_EXCLUDE_PATH"
    fi
    return 0
}

# count_recent_destructive_ops -> prints the count of recorded destructive
# DELETEs within the last BULK_DESTRUCTIVE_WINDOW_SECS. Window-only (NOT
# per-run): a simple "N in the last X minutes" rate limit is both simpler and
# strictly safer than per-run scoping (per-run resets the counter every run
# and is more permissive). jq -R -n + inputs idiom mirrors the reverse guard.
count_recent_destructive_ops() {
    [[ -f "$BULK_DESTRUCTIVE_PATH" ]] || { echo 0; return 0; }
    local cutoff_epoch=$(( $(date +%s) - BULK_DESTRUCTIVE_WINDOW_SECS ))
    jq -R -r -n \
        --argjson cutoff "$cutoff_epoch" \
        '[inputs | fromjson? // empty | select(type == "object")]
         | map(select((.epoch // 0) >= $cutoff))
         | length' \
        "$BULK_DESTRUCTIVE_PATH" 2>/dev/null || echo 0
}

# enforce_bulk_destructive_gate METHOD PATH -> 0 allow / 1 block.
# Runs in cmd_call after the merge guard, before the dry-run short-circuit.
enforce_bulk_destructive_gate() {
    local method="$1" path="$2"
    is_bulk_destructive_op "$method" "$path" || return 0
    is_dry_run_mode && return 0

    local count
    count="$(count_recent_destructive_ops)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if (( count >= BULK_DESTRUCTIVE_THRESHOLD )); then
        # Threshold reached. Require an EXPLICIT second approval REGARDLESS of
        # requester (do not exempt by requester identity; that omission is the
        # point — the agent auto-stamps --requester with whoever is in-thread).
        if [[ -z "$CONFIRMED_BY" ]]; then
            cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED: ${count} destructive DELETE(s) in the last ${BULK_DESTRUCTIVE_WINDOW_SECS}s have reached the bulk threshold (${BULK_DESTRUCTIVE_THRESHOLD}).
This is the 2026-05-26 incident class (285 analytics-source DELETEs off one vague request). STOP autonomous deletion now.

To proceed you must have an EXPLICIT in-thread human decision to delete this many records, then pass BOTH:
    --confirmed-by <handle>   (one of: $(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | tr '\n' ' '))
    --approval-msg-id <slack_ts>

Requester identity does NOT bypass this gate, and a stale/reused approval-msg-id is not a substitute for a real per-batch decision. Each call past the threshold needs genuine approval. If the operation is genuinely this large, hand it to a human to run.
EOF
            return 1
        fi
        if ! is_tier2_approver "$CONFIRMED_BY"; then
            cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_APPROVAL_INVALID: --confirmed-by '${CONFIRMED_BY}' is not in the tier-2 approver allowlist.
Allowed approvers (from $TIER2_APPROVERS_PATH):
$(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | sed 's/^/  - /' || echo "  (file missing)")
EOF
            return 1
        fi
        if [[ -z "$APPROVAL_MSG_ID" ]]; then
            echo "MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED: --approval-msg-id <slack_ts> is required alongside --confirmed-by for bulk-destructive writes (audit trail)." >&2
            return 1
        fi

        # Audit the approved bulk-destructive write BEFORE executing. Fail-closed
        # if the audit can't be written — "deleted en masse, no record of who
        # approved it" is the worse failure mode.
        if ! mkdir -p "$(dirname "$BULK_DESTRUCTIVE_AUDIT_PATH")" 2>/dev/null; then
            echo "MUSO_BULK_DESTRUCTIVE_AUDIT_UNWRITABLE: cannot create $(dirname "$BULK_DESTRUCTIVE_AUDIT_PATH") — refusing bulk-destructive write to preserve audit trail." >&2
            return 1
        fi
        local ts audit_rc=0
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        jq -n -c \
            --arg ts "$ts" \
            --arg method "$method" \
            --arg path "$path" \
            --arg requester "${REQUESTER_EMAIL:-}" \
            --arg confirmed_by "$CONFIRMED_BY" \
            --arg approval_msg_id "$APPROVAL_MSG_ID" \
            --argjson count_at_trip "$count" \
            --argjson threshold "$BULK_DESTRUCTIVE_THRESHOLD" \
            --argjson window_secs "$BULK_DESTRUCTIVE_WINDOW_SECS" \
            '{ts:$ts, method:$method, path:$path, requester:$requester, confirmed_by:$confirmed_by, approval_msg_id:$approval_msg_id, count_at_trip:$count_at_trip, threshold:$threshold, window_secs:$window_secs}' \
            >> "$BULK_DESTRUCTIVE_AUDIT_PATH" || audit_rc=$?
        if (( audit_rc != 0 )); then
            echo "MUSO_BULK_DESTRUCTIVE_AUDIT_UNWRITABLE: append to $BULK_DESTRUCTIVE_AUDIT_PATH failed (rc=$audit_rc) — refusing bulk-destructive write to preserve audit trail." >&2
            return 1
        fi
    fi

    # Record this attempt BEFORE the DELETE is issued, and FAIL CLOSED if it
    # cannot be persisted. Otherwise an unwritable state dir leaves the counter
    # at 0 forever and silently disables the gate — unlimited deletes with no
    # threshold (QA, PR #390). Runs for BOTH under-threshold and approved calls.
    if ! record_destructive_op "$method" "$path"; then
        echo "MUSO_BULK_DESTRUCTIVE_COUNTER_UNWRITABLE: cannot persist the destructive-op counter (${BULK_DESTRUCTIVE_PATH}) — refusing the DELETE. The gate must record this call to bound the blast radius; fix the state dir (MUSO_OPS_STATE_DIR=${MUSO_OPS_STATE_DIR}) and retry." >&2
        return 1
    fi
    return 0
}

# record_destructive_op METHOD PATH -> 0 recorded (or no-op), 1 could-not-persist.
# Records the destructive DELETE ATTEMPT to the rolling counter. FAIL-CLOSED: a
# write failure returns non-zero so the caller (enforce_bulk_destructive_gate)
# refuses the DELETE rather than letting the counter sit at 0 forever and
# silently disable the guard (QA, PR #390). Called from the gate BEFORE the curl
# — counting the attempt (not only a 2xx) lands the record before the
# irreversible call and over-counts toward safety.
record_destructive_op() {
    local method="$1" path="$2"
    is_bulk_destructive_op "$method" "$path" || return 0
    is_dry_run_mode && return 0
    local _path="${path%%\?*}"
    mkdir -p "$(dirname "$BULK_DESTRUCTIVE_PATH")" 2>/dev/null || return 1
    local epoch ts line
    epoch=$(date +%s)
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    line=$(jq -n -c \
        --arg ts "$ts" \
        --argjson epoch "$epoch" \
        --arg method "$method" \
        --arg path "$_path" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        '{ts:$ts, epoch:$epoch, method:$method, path:$path, requester:$requester}' 2>/dev/null) || return 1
    printf '%s\n' "$line" >> "$BULK_DESTRUCTIVE_PATH" 2>/dev/null || return 1
    return 0
}

# --- Codex model-health gate (incident 2026-06-08) ---
# A silent codex auth-permanent / refresh-token-race degradation drops the WHOLE fleet
# onto a weak fallback model (openrouter/openai/gpt-5.4-mini) that the agent CANNOT
# perceive — openclaw's `Model Fallback:` banner is built on the delivery path and is
# never injected into the prompt (memory reference_agent_cannot_see_own_fallback_state).
# On 2026-06-08 that degraded model misrouted a track-metadata fix into the credit-
# verification batch and fabricated a ticket + human handoff. SOUL doctrine alone can't
# stop this (the agent can't read its own model state), so this is the mechanical guard:
# refuse state-changing WRITES while codex is degraded, returning a hard error in the
# tool RESULT — the one signal the agent CAN see — so it reports "couldn't complete,
# deferring" instead of acting on bad judgment. READS (GET/HEAD) pass through untouched
# so the agent can still investigate while degraded.
#
# Shares the exact probe the Stripe money-path uses (scripts/lib/codex-health.sh ->
# codex_health_gate), so admin writes can never drift to a weaker check than refunds.
# FAIL-CLOSED: an unreadable journal or a missing lib refuses the write. Self-skips in
# dry-run (no prod mutation) only — there is deliberately NO caller-settable bypass
# (matching the Stripe money-path gate), so the degraded model this guards against
# cannot disable it by setting a per-command env var when it invokes the tool.
CODEX_HEALTH_LIB="${CODEX_HEALTH_LIB:-/opt/hydra/scripts/lib/codex-health.sh}"
CODEX_HEALTH_GATEWAY_UNIT="${OPENCLAW_GATEWAY_UNIT:-openclaw-gateway-main}"
CODEX_HEALTH_WINDOW_MIN="${CODEX_HEALTH_WINDOW_MIN:-5}"

enforce_codex_health_gate() {
    local method="$1"
    # Reads always allowed — only state-changing writes are gated.
    local method_lc
    method_lc="$(printf %s "$method" | tr '[:upper:]' '[:lower:]')"
    case "$method_lc" in
        get|head) return 0 ;;
    esac
    # Dry-run never touches prod; skip (consistent with every other gate here).
    is_dry_run_mode && return 0

    # Missing lib = packaging/rsync regression → fail closed rather than skip the check.
    if [[ ! -r "$CODEX_HEALTH_LIB" ]]; then
        echo "MUSO_CODEX_HEALTH_LIB_MISSING: cannot read codex-health lib at ${CODEX_HEALTH_LIB} — refusing the ${method} write (model health unverifiable). Restore scripts/lib/codex-health.sh on the host." >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "$CODEX_HEALTH_LIB"

    local reason rc=0
    reason="$(codex_health_gate "$CODEX_HEALTH_GATEWAY_UNIT" "$CODEX_HEALTH_WINDOW_MIN" 2>&1)" || rc=$?
    if (( rc != 0 )); then
        cat >&2 <<EOF
MUSO_CODEX_DEGRADED: refusing ${method} write — ${reason}.
The agent may be on a weak fallback model it cannot perceive (openclaw's
\`Model Fallback:\` banner is delivery-only, never in the prompt). A degraded
model must not issue admin writes. The write did NOT execute.
Report plainly that it did not complete and defer to a human — @-mention Nick
(<@U0AL36NADEY>). Reads are still available. Retry once codex health is
confirmed (\`openclaw --profile main agents list\`).
EOF
        return 1
    fi
    return 0
}

cmd_call() {
    check_env
    local method="${1:?Usage: call <METHOD> <path> [json-body]}"
    local path="${2:?Usage: call <METHOD> <path> [json-body]}"
    local body="${3:-}"

    # Misplaced-flag guard (incident 2026-06-30). Global flags (--requester /
    # --confirmed-by / --approval-msg-id / --profile-audit-id) MUST precede the
    # `call` subcommand. If one is left AFTER the path it lands here as the
    # positional JSON body; the API then 400s on a body-parse failure that
    # core-backend masks behind a generic "Unavailable service" message — which
    # reads as a phantom service outage (a one-char typo cost hours of false
    # alarm). A real JSON body never starts with "--", so this is unambiguous.
    # Fail loud instead of POSTing a malformed body. (See dispatcher-arg-validation.)
    case "$body" in
        --*)
            cat >&2 <<EOF
muso-admin-api: refusing — request body looks like a misplaced flag: '${body}'
  Global flags go BEFORE the command. Did you mean:
    bash $0 ${body} <value> call ${method} ${path}
EOF
            return 2
            ;;
    esac

    # Codex model-health gate (incident 2026-06-08). Refuse WRITES while the fleet is
    # silently degraded onto a weak fallback model the agent can't perceive; READS pass
    # through. Runs first so a degraded model is stopped before any other gate logic.
    if ! enforce_codex_health_gate "$method"; then
        return 1
    fi

    # Credit approve gate — deterministic, runs in bash below openclaw's hook layer.
    if ! enforce_credit_approve_gate "$method" "$path" "$body"; then
        return 1
    fi

    # Credit reject gate (incident 2026-07-22). Rejection is never autonomous —
    # requires --confirmed-by + --approval-msg-id. Runs even in dry-run.
    if ! enforce_credit_reject_gate "$method" "$path" "$body"; then
        return 1
    fi

    # Tier-2 approval gate (incident 2026-04-29). Skipped in dry-run mode.
    if ! enforce_tier2_approval_gate "$method" "$path"; then
        return 1
    fi

    # Reverse-direction guard for /admin/profiles/merge (incident 2026-04-29).
    if ! enforce_merge_reverse_direction_guard "$method" "$path" "$body"; then
        return 1
    fi

    # Bulk destructive-operation gate (incident 2026-05-26). Caps the blast
    # radius of mass DELETEs. Self-skips in dry-run.
    if ! enforce_bulk_destructive_gate "$method" "$path"; then
        return 1
    fi

    # Dry-run short-circuit (issue #145). Gate ran above, so a broken batch
    # still fails loudly. Fail-CLOSED method check: anything that isn't a
    # pure read (GET/HEAD, case-insensitive) is intercepted. This prevents
    # lower-case `put`, typos, and future verbs from bypassing dry-run.
    if is_dry_run_mode; then
        local method_lc
        method_lc="$(printf %s "$method" | tr '[:upper:]' '[:lower:]')"
        case "$method_lc" in
            get|head)
                : # read — fall through to real API
                ;;
            *)
                DRY_RUN_AUDIT_FAILED=0
                write_dry_run_audit "$method" "$path" "$body" "call"
                emit_dry_run_response
                return 0
                ;;
        esac
    fi

    local token
    token=$(get_token)

    local -a curl_args=(
        -s -w "\n%{http_code}"
        -X "$method"
        "${MUSO_API_URL}${path}"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -H "Service: clio"
    )

    # Add Requester header if set (audit trail — tells backend which human initiated this)
    if [[ -n "$REQUESTER_EMAIL" ]]; then
        curl_args+=(-H "Requester: $REQUESTER_EMAIL")
    fi

    if [[ -n "$body" ]]; then
        curl_args+=(-d "$body")
    fi

    local response
    response=$(curl "${curl_args[@]}")

    # Extract HTTP status code (last line) and body (everything else)
    local http_code
    http_code=$(echo "$response" | tail -1)
    local response_body
    response_body=$(echo "$response" | sed '$d')

    # Record successful merges for the reverse-direction guard.
    record_merge_call "$method" "$path" "$body" "$http_code"

    # Output JSON with status
    echo "{\"http_status\": $http_code, \"body\": $response_body}" 2>/dev/null \
        || echo "{\"http_status\": $http_code, \"raw\": $(echo "$response_body" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}"
}

cmd_upload() {
    check_env
    local path="${1:?Usage: upload <path> <file> [field=value...]}"
    local file="${2:?Usage: upload <path> <file> [field=value...]}"
    shift 2

    [[ -f "$file" ]] || die "File not found: $file"

    # Codex model-health gate — uploads are always writes (POST). Refuse while the
    # fleet is degraded; self-skips in dry-run.
    if ! enforce_codex_health_gate "POST"; then
        return 1
    fi

    # Uploads are always writes — short-circuit unconditionally in dry-run.
    if is_dry_run_mode; then
        DRY_RUN_AUDIT_FAILED=0
        write_dry_run_audit "POST" "$path" "$file" "upload"
        emit_dry_run_response
        return 0
    fi

    local token
    token=$(get_token)

    local -a curl_args=(
        -s -w "\n%{http_code}"
        -X POST
        "${MUSO_API_URL}${path}"
        -H "Authorization: Bearer $token"
        -H "Service: clio"
    )

    # Add Requester header if set
    if [[ -n "$REQUESTER_EMAIL" ]]; then
        curl_args+=(-H "Requester: $REQUESTER_EMAIL")
    fi

    curl_args+=(-F "file=@$file")

    for field in "$@"; do
        curl_args+=(-F "$field")
    done

    local response
    response=$(curl "${curl_args[@]}")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local response_body
    response_body=$(echo "$response" | sed '$d')

    echo "{\"http_status\": $http_code, \"body\": $response_body}" 2>/dev/null \
        || echo "{\"http_status\": $http_code, \"raw\": $(echo "$response_body" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}"
}

# --- Main ---

# Source-safe guard: if this file is `source`d (e.g. by bats tests), skip the
# CLI dispatcher and only expose the function definitions. Executed directly,
# the dispatcher runs normally.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0 2>/dev/null || true
fi

# Parse global options before command.
# Both --requester and --evidence-excerpt can appear in any order before the command.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --requester)
            REQUESTER_EMAIL=$(resolve_slack_to_email "$2")
            shift 2
            ;;
        --evidence-excerpt)
            EVIDENCE_EXCERPT="$2"
            export EVIDENCE_EXCERPT  # enforce_credit_approve_gate reads it from env
            shift 2
            ;;
        --confirmed-by)
            CONFIRMED_BY="$2"
            shift 2
            ;;
        --approval-msg-id)
            APPROVAL_MSG_ID="$2"
            shift 2
            ;;
        *) break ;;
    esac
done

command="${1:-help}"
shift || true

case "$command" in
    login)          cmd_login "$@" ;;
    call)           cmd_call "$@" ;;
    upload)         cmd_upload "$@" ;;
    resolve-email)  resolve_slack_to_email "${1:?Usage: resolve-email <slack_id>}" ;;
    help)           head -14 "$0" | tail -13 | sed 's/^# //' | sed 's/^#//' ;;
    *)              die "Unknown command: $command" ;;
esac
