#!/usr/bin/env bash
# devops-set-env.sh — guarded prod environment-variable setter for the DevOps agent.
#
# This is the ONLY sanctioned path for the DevOps agent to set a production env
# variable. Every gate below runs in bash, BELOW the LLM — the agent cannot talk
# its way past them. The design mirrors muso-ops-admin/scripts/muso-admin-api.sh
# (requester attribution, fail-closed config, dry-run, window rate-gate, JSONL
# audit) rather than re-deriving any of it.
#
# Usage:
#   bash devops-set-env.sh --requester <slack_id|email> \
#        set --target <service> --key <KEY> --value <VALUE> [--reason "..."] \
#        [--confirmed-by <handle> --approval-msg-id <slack_ts>]
#   bash devops-set-env.sh --requester <id> rollback --target <service> --key <KEY>
#   bash devops-set-env.sh resolve-email <slack_id>
#
# ─── IMPORTANT: the blocklist is NOT the real wall ──────────────────────────
# The DevOps agent runs with exec security=full, ask=off and already holds a
# raw Vault AppRole + SSH + kubectl. A bash blocklist alone is bypassable. Real
# enforcement REQUIRES that the backend (see backend_write) authenticate as a
# SCOPED credential — a Vault policy / K8s Role that can write ONLY the
# allow-listed non-secret keys. Until that scoped credential is provisioned
# (Artem/Aaron) and the backend is pinned in Phase-0 verification, the real
# write backend stays fail-closed. See SKILL.md.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required but not found" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Config (fail-closed; override paths for tests) ---
PROTECTED_KEYS_PATH="${PROTECTED_KEYS_PATH:-${SCRIPT_DIR}/../config/protected-env-keys.txt}"
TARGET_ALLOWLIST_PATH="${TARGET_ALLOWLIST_PATH:-${SCRIPT_DIR}/../config/target-allowlist.txt}"
ENVSET_REQUESTERS_PATH="${ENVSET_REQUESTERS_PATH:-${SCRIPT_DIR}/../config/envset-requesters.txt}"
# Who can GREEN-LIGHT a blocklisted (secret-shaped) set. A blocklisted key is
# refused unless --confirmed-by names someone here + --approval-msg-id is given.
BLOCKLIST_OVERRIDE_APPROVERS_PATH="${BLOCKLIST_OVERRIDE_APPROVERS_PATH:-${SCRIPT_DIR}/../config/blocklist-override-approvers.txt}"

# --- State + audit (override for tests) ---
# /var/log/muso-devops is hydra's canonical location; tests override it.
DEVOPS_ENVSET_STATE_DIR="${DEVOPS_ENVSET_STATE_DIR:-/var/log/muso-devops}"
RATE_PATH="${RATE_PATH:-${DEVOPS_ENVSET_STATE_DIR}/envset-ops.jsonl}"
AUDIT_PATH="${AUDIT_PATH:-${DEVOPS_ENVSET_STATE_DIR}/envset-audit-$(date -u +%Y-%m-%d).jsonl}"

# --- Rate gate (window-only, mirrors the bulk-destructive gate) ---
# Once ENVSET_THRESHOLD sets land within ENVSET_WINDOW_SECS, every further set
# is refused until an explicit human ack (--confirmed-by in the requester
# allowlist + --approval-msg-id). Autonomy is bounded, not unlimited.
ENVSET_THRESHOLD="${ENVSET_THRESHOLD:-5}"
ENVSET_WINDOW_SECS="${ENVSET_WINDOW_SECS:-900}"
if ! [[ "$ENVSET_THRESHOLD" =~ ^[1-9][0-9]*$ ]]; then
    echo "FATAL: ENVSET_THRESHOLD must be a positive integer (got '${ENVSET_THRESHOLD}')" >&2; exit 1
fi
if ! [[ "$ENVSET_WINDOW_SECS" =~ ^[1-9][0-9]*$ ]]; then
    echo "FATAL: ENVSET_WINDOW_SECS must be a positive integer (got '${ENVSET_WINDOW_SECS}')" >&2; exit 1
fi

# --- Dry-run (deny-list parse, mirrors muso-admin-api.sh:85-95) ---
case "$(printf %s "${OPS_DRY_RUN:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)     OPS_DRY_RUN=1 ;;
    0|false|no|off|"") OPS_DRY_RUN=0 ;;
    *) echo "WARN: OPS_DRY_RUN='${OPS_DRY_RUN}' not recognized; treating as false. Use 1|true|yes|on to enable." >&2
       OPS_DRY_RUN=0 ;;
esac
is_dry_run() { [[ "$OPS_DRY_RUN" == "1" ]]; }

# --- Backend selection ---
# DEVOPS_ENVSET_BACKEND pins HOW the value is read/written:
#   stub   — tests/dry-run demos: a flat KEY=VALUE file at DEVOPS_ENVSET_STUB_STORE.
#   kubectl|vault — REAL prod backends. Pinned in Phase-0 verification on node-8
#                   against H-DevOps; until then they refuse (fail-closed).
#   (unset) — refuse. We never hit prod by default.
DEVOPS_ENVSET_BACKEND="${DEVOPS_ENVSET_BACKEND:-}"

# --- Flags ---
REQUESTER_RAW=""; REQUESTER_EMAIL=""
TARGET=""; KEY=""; VALUE=""; VALUE_SET=0; REASON=""
CONFIRMED_BY=""; APPROVAL_MSG_ID=""
BLOCKLIST_OVERRIDDEN=0   # set to 1 when a blocklisted key proceeds via green-light

# Placeholder written to the audit log (and surfaced in the rollback hint) in
# place of a secret-shaped value, so a green-lit credential is never persisted
# to /var/log/muso-devops or echoed to the console.
REDACTED_MARKER="[REDACTED:secret-shaped]"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Slack ID → email (kept in sync with muso-admin-api.sh:198-222) ---
resolve_slack_to_email() {
    local input="$1"
    [[ "$input" == *@* ]] && { echo "$input"; return 0; }
    case "$input" in
        U7RP6HKUZ)   echo "aaron@muso.ai" ;;
        U03TYGJF1N3) echo "serhii@muso.ai" ;;
        U038BM16T7W) echo "jan@muso.ai" ;;
        U02S7TJ7QHY) echo "oleg@muso.ai" ;;
        U0AL36NADEY) echo "nick@muso.ai" ;;
        U0A8CCTTAAG) echo "liza@muso.ai" ;;
        *) echo "$input"; return 1 ;;
    esac
    return 0
}

# Lowercase a string (bash 3.2-safe — no ${x,,}).
lc() { printf %s "$1" | tr '[:upper:]' '[:lower:]'; }
uc() { printf %s "$1" | tr '[:lower:]' '[:upper:]'; }

# Read a config file into non-comment, trimmed lines on stdout. Returns 1 if
# the file is missing so callers can fail closed.
read_config_lines() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' "$path"
}

# --- Gate: requester authorized (DevOps-tier humans only) ---
# Fail-closed: a missing allowlist refuses everyone.
authorize_requester() {
    local lines
    if ! lines="$(read_config_lines "$ENVSET_REQUESTERS_PATH")"; then
        echo "DEVOPS_ENVSET_CONFIG_MISSING: requester allowlist ${ENVSET_REQUESTERS_PATH} is missing — refusing every set until it is restored." >&2
        return 1
    fi
    local want; want="$(lc "$REQUESTER_EMAIL")"
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$(lc "$line")" == "$want" ]] && return 0
    done <<< "$lines"
    echo "DEVOPS_ENVSET_REQUESTER_DENIED: '${REQUESTER_EMAIL}' is not in the env-set requester allowlist (${ENVSET_REQUESTERS_PATH}). Only DevOps-tier humans may drive prod env changes." >&2
    return 1
}

# is_protected_key KEY -> 0 if blocklisted (secret-shaped), 1 otherwise.
# Case-insensitive glob match. FAIL-CLOSED: a missing blocklist treats EVERY
# key as protected (refuse all) — the opposite of the bulk-destructive
# exclude-list, because here a missing list must never widen autonomy.
is_protected_key() {
    local key_uc; key_uc="$(uc "$1")"
    local lines
    if ! lines="$(read_config_lines "$PROTECTED_KEYS_PATH")"; then
        echo "DEVOPS_ENVSET_CONFIG_MISSING: blocklist ${PROTECTED_KEYS_PATH} is missing — treating every key as protected (refusing) to fail closed." >&2
        return 0
    fi
    local pat pat_uc
    while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        pat_uc="$(uc "$pat")"
        # RHS intentionally unquoted so glob `*` is active.
        # shellcheck disable=SC2053
        [[ "$key_uc" == $pat_uc ]] && return 0
    done <<< "$lines"
    return 1
}

# is_override_approver HANDLE -> 0 if the handle can green-light a blocklisted
# (secret-shaped) set. Fail-closed: a missing approver file refuses every override.
is_override_approver() {
    local want; want="$(lc "$1")"
    local lines line
    lines="$(read_config_lines "$BLOCKLIST_OVERRIDE_APPROVERS_PATH")" || return 1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$(lc "$line")" == "$want" ]] && return 0
    done <<< "$lines"
    return 1
}

# enforce_blocklist_override -> 0 if a valid green-light is present for a
# blocklisted key, 1 otherwise (caller refuses with exit 4). A secret-shaped set
# is NEVER autonomous: it requires an explicit human green-light (--confirmed-by
# in BLOCKLIST_OVERRIDE_APPROVERS_PATH + --approval-msg-id tying it to the Slack
# approval). Even OPS_DRY_RUN requires the green-light, so a dry-run faithfully
# shows whether the real set would be allowed.
enforce_blocklist_override() {
    if [[ -z "$CONFIRMED_BY" ]]; then
        cat >&2 <<EOF
DEVOPS_ENVSET_KEY_BLOCKED: '${KEY}' is secret-shaped / on the blocklist (${PROTECTED_KEYS_PATH}). This is NEVER autonomous.
→ ASK FOR A GREEN LIGHT: post the requested change to an approver ($(read_config_lines "$BLOCKLIST_OVERRIDE_APPROVERS_PATH" 2>/dev/null | tr '\n' ' ')) and WAIT for explicit approval.
On approval, re-run with: --confirmed-by <approver> --approval-msg-id <slack_ts_of_the_green_light>
EOF
        return 1
    fi
    if ! is_override_approver "$CONFIRMED_BY"; then
        echo "DEVOPS_ENVSET_OVERRIDE_INVALID: --confirmed-by '${CONFIRMED_BY}' cannot green-light a blocklisted key. Approvers (${BLOCKLIST_OVERRIDE_APPROVERS_PATH}): $(read_config_lines "$BLOCKLIST_OVERRIDE_APPROVERS_PATH" 2>/dev/null | tr '\n' ' ')" >&2
        return 1
    fi
    if [[ -z "$APPROVAL_MSG_ID" ]]; then
        echo "DEVOPS_ENVSET_OVERRIDE_REQUIRED: --approval-msg-id <slack_ts> is required alongside --confirmed-by for a blocklisted-key green-light (audit trail)." >&2
        return 1
    fi
    return 0
}

# --- Gate: target allow-listed (exact match, fail-closed) ---
is_allowed_target() {
    local lines
    if ! lines="$(read_config_lines "$TARGET_ALLOWLIST_PATH")"; then
        echo "DEVOPS_ENVSET_CONFIG_MISSING: target allowlist ${TARGET_ALLOWLIST_PATH} is missing — refusing every set until it is restored." >&2
        return 1
    fi
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == "$TARGET" ]] && return 0
    done <<< "$lines"
    echo "DEVOPS_ENVSET_TARGET_DENIED: target '${TARGET}' is not in the allowlist (${TARGET_ALLOWLIST_PATH})." >&2
    return 1
}

# --- Rate gate (window-only count, mirrors count_recent_destructive_ops) ---
count_recent_sets() {
    [[ -f "$RATE_PATH" ]] || { echo 0; return 0; }
    local cutoff=$(( $(date +%s) - ENVSET_WINDOW_SECS ))
    jq -R -r -n --argjson cutoff "$cutoff" \
        '[inputs | fromjson? // empty | select(type=="object")]
         | map(select((.epoch // 0) >= $cutoff)) | length' \
        "$RATE_PATH" 2>/dev/null || echo 0
}

record_set_op() {
    mkdir -p "$(dirname "$RATE_PATH")" 2>/dev/null || return 1
    jq -n -c --argjson epoch "$(date +%s)" --arg key "$KEY" --arg target "$TARGET" \
        --arg requester "$REQUESTER_EMAIL" \
        '{epoch:$epoch, key:$key, target:$target, requester:$requester}' \
        >> "$RATE_PATH" 2>/dev/null || return 1
    return 0
}

# requester_is_approver HANDLE -> 0 if the ack handle is itself in the requester
# allowlist. The rate-cap ack reuses the same DevOps-tier list (YAGNI: no fourth
# config file). The point of the ack is a fresh human decision, captured by
# --approval-msg-id, not a wider set of people.
requester_is_approver() {
    local want; want="$(lc "$1")"
    local lines line
    lines="$(read_config_lines "$ENVSET_REQUESTERS_PATH")" || return 1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$(lc "$line")" == "$want" ]] && return 0
    done <<< "$lines"
    return 1
}

enforce_rate_gate() {
    # NB: dry-run evaluates this gate too (it does NOT early-return), so a
    # preflight faithfully reports a would-be rate block — mirroring the
    # blocklist override's dry-run philosophy. The rate COUNTER is left
    # unmutated by dry-run at the record_set_op call site, so previews never
    # consume the burst budget.
    local count; count="$(count_recent_sets)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    (( count < ENVSET_THRESHOLD )) && return 0
    if [[ -z "$CONFIRMED_BY" ]]; then
        cat >&2 <<EOF
DEVOPS_ENVSET_RATE_APPROVAL_REQUIRED: ${count} env set(s) in the last ${ENVSET_WINDOW_SECS}s have reached the threshold (${ENVSET_THRESHOLD}).
STOP autonomous sets. A burst of env changes is incident-shaped. To proceed, get an explicit human decision and pass BOTH:
    --confirmed-by <handle>   (one of: $(read_config_lines "$ENVSET_REQUESTERS_PATH" 2>/dev/null | tr '\n' ' '))
    --approval-msg-id <slack_ts>
EOF
        return 1
    fi
    if ! requester_is_approver "$CONFIRMED_BY"; then
        echo "DEVOPS_ENVSET_RATE_APPROVAL_INVALID: --confirmed-by '${CONFIRMED_BY}' is not in ${ENVSET_REQUESTERS_PATH}." >&2
        return 1
    fi
    [[ -n "$APPROVAL_MSG_ID" ]] || { echo "DEVOPS_ENVSET_RATE_APPROVAL_REQUIRED: --approval-msg-id <slack_ts> is required alongside --confirmed-by." >&2; return 1; }
    return 0
}

# --- Audit (pre-execution, FAIL-CLOSED) ---
# Captures the rollback value (prev) so a bad set is reversible from the log.
write_audit() {
    local prev="$1" result="$2"
    if ! mkdir -p "$(dirname "$AUDIT_PATH")" 2>/dev/null; then
        echo "DEVOPS_ENVSET_AUDIT_UNWRITABLE: cannot create $(dirname "$AUDIT_PATH") — refusing the set to preserve the audit trail." >&2
        return 1
    fi
    # Redact secret-shaped (blocklist-overridden) values so a green-lit
    # credential is never persisted to the audit JSONL. The record still
    # captures WHO set WHICH key on WHAT target, with the green-light
    # attribution — just not the secret material itself.
    local prev_logged="$prev" new_logged="$VALUE"
    if [[ "$BLOCKLIST_OVERRIDDEN" == "1" ]]; then
        prev_logged="$REDACTED_MARKER"
        new_logged="$REDACTED_MARKER"
    fi
    local line
    line="$(jq -n -c \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg requester "$REQUESTER_EMAIL" \
        --arg target "$TARGET" --arg key "$KEY" \
        --arg prev "$prev_logged" --arg new "$new_logged" \
        --arg reason "$REASON" --arg confirmed_by "$CONFIRMED_BY" \
        --arg approval_msg_id "$APPROVAL_MSG_ID" \
        --arg backend "$DEVOPS_ENVSET_BACKEND" --arg result "$result" \
        --argjson dry_run "$([[ "$OPS_DRY_RUN" == "1" ]] && echo true || echo false)" \
        --argjson blocklist_override "$([[ "$BLOCKLIST_OVERRIDDEN" == "1" ]] && echo true || echo false)" \
        '{ts:$ts, requester:$requester, target:$target, key:$key,
          prev_value:$prev, new_value:$new, reason:$reason,
          blocklist_override:$blocklist_override,
          confirmed_by:(if $confirmed_by=="" then null else $confirmed_by end),
          approval_msg_id:(if $approval_msg_id=="" then null else $approval_msg_id end),
          backend:$backend, dry_run:$dry_run, result:$result}' 2>/dev/null)" \
        || { echo "DEVOPS_ENVSET_AUDIT_UNWRITABLE: jq failed to build audit line — refusing the set." >&2; return 1; }
    printf '%s\n' "$line" >> "$AUDIT_PATH" 2>/dev/null \
        || { echo "DEVOPS_ENVSET_AUDIT_UNWRITABLE: append to ${AUDIT_PATH} failed — refusing the set." >&2; return 1; }
    return 0
}

# --- Backend (Phase-0-pending for real prod; stub for tests/dry-run) ---
backend_read_current() {
    case "$DEVOPS_ENVSET_BACKEND" in
        stub)
            [[ -f "${DEVOPS_ENVSET_STUB_STORE:-}" ]] || { echo ""; return 0; }
            # last value wins; print empty if absent
            grep -E "^${KEY}=" "$DEVOPS_ENVSET_STUB_STORE" 2>/dev/null | tail -1 | sed "s/^${KEY}=//" || echo ""
            ;;
        kubectl|vault)
            echo "" ;;  # Phase-0: real read pinned on node-8 against H-DevOps
        *) echo "" ;;
    esac
}

backend_write() {
    case "$DEVOPS_ENVSET_BACKEND" in
        stub)
            [[ -n "${DEVOPS_ENVSET_STUB_STORE:-}" ]] || { echo "stub backend needs DEVOPS_ENVSET_STUB_STORE" >&2; return 1; }
            mkdir -p "$(dirname "$DEVOPS_ENVSET_STUB_STORE")" 2>/dev/null || return 1
            printf '%s=%s\n' "$KEY" "$VALUE" >> "$DEVOPS_ENVSET_STUB_STORE" || return 1
            return 0 ;;
        kubectl|vault)
            # FAIL-CLOSED until Phase-0 pins the exact command AND the scoped
            # credential exists. Do NOT implement against unverified paths.
            echo "DEVOPS_ENVSET_BACKEND_NOT_PINNED: backend='${DEVOPS_ENVSET_BACKEND}' is not yet wired. Phase-0 verification on node-8 (against H-DevOps) must pin the exact write command, and Artem/Aaron must provision the scoped Vault policy / K8s Role this authenticates as. Refusing to guess a prod write." >&2
            return 1 ;;
        *)
            echo "DEVOPS_ENVSET_BACKEND_UNSET: set DEVOPS_ENVSET_BACKEND (stub for tests; kubectl/vault once Phase-0-pinned). Refusing." >&2
            return 1 ;;
    esac
}

restore_hint() {
    local prev="$1"
    # Never echo a secret-shaped value: at set-time BLOCKLIST_OVERRIDDEN==1; at
    # rollback-time the audit log already holds the redaction marker (the real
    # prior value was never persisted).
    if [[ "$BLOCKLIST_OVERRIDDEN" == "1" || "$prev" == "$REDACTED_MARKER" ]]; then
        echo "↩ rollback: ${KEY} is secret-shaped; its prior value is not echoed here. Roll it back via the secret-management path (Vault/K8s), not this wrapper."
    elif [[ -z "$prev" ]]; then
        echo "↩ rollback: ${KEY} had NO prior value on ${TARGET}; unset it to revert."
    else
        # printf %q shell-escapes the prior value so the printed command is safe
        # to paste even if it contains quotes, newlines, or metacharacters.
        local prev_q; prev_q="$(printf '%q' "$prev")"
        echo "↩ rollback: bash devops-set-env.sh --requester <id> set --target ${TARGET} --key ${KEY} --value ${prev_q} --reason 'rollback'"
    fi
}

cmd_set() {
    [[ -n "$REQUESTER_EMAIL" ]] || die "--requester is required"
    [[ -n "$TARGET" ]] || die "set requires --target"
    [[ -n "$KEY" ]]    || die "set requires --key"
    [[ "$VALUE_SET" == "1" ]] || die "set requires --value"
    [[ "$KEY" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid env key '${KEY}' (expected [A-Za-z_][A-Za-z0-9_]*)"

    authorize_requester || exit 3

    if is_protected_key "$KEY"; then
        # Not a dead-end: a blocklisted key proceeds ONLY with an explicit human
        # green-light (--confirmed-by an override-approver + --approval-msg-id).
        enforce_blocklist_override || exit 4
        BLOCKLIST_OVERRIDDEN=1
    fi

    is_allowed_target || exit 5
    enforce_rate_gate || exit 6

    local prev; prev="$(backend_read_current)"

    # Audit BEFORE the write; fail-closed.
    write_audit "$prev" "attempted" || exit 7
    # Record toward the rate window BEFORE the write; fail-closed (an unwritable
    # counter must not silently disable the gate). A dry-run is a preview: it
    # already exercised the rate decision above, but must NOT consume the burst
    # budget, so the counter is left untouched here.
    if ! is_dry_run; then
        record_set_op || { echo "DEVOPS_ENVSET_COUNTER_UNWRITABLE: cannot persist the rate counter (${RATE_PATH}) — refusing the set." >&2; exit 7; }
    fi

    if is_dry_run; then
        echo "{\"dryRun\":true,\"target\":\"${TARGET}\",\"key\":\"${KEY}\",\"wouldHaveExecuted\":true}"
        restore_hint "$prev"
        return 0
    fi

    if backend_write; then
        echo "✅ set ${KEY} on ${TARGET} (backend=${DEVOPS_ENVSET_BACKEND})."
        restore_hint "$prev"
    else
        write_audit "$prev" "failed" || true
        exit 8
    fi
}

cmd_rollback() {
    # Convenience: surface the last recorded prev value from the audit log.
    [[ -n "$TARGET" && -n "$KEY" ]] || die "rollback requires --target and --key"
    [[ -f "$AUDIT_PATH" ]] || die "no audit log at ${AUDIT_PATH}"
    local prev
    prev="$(jq -r -n --arg t "$TARGET" --arg k "$KEY" \
        '[inputs | select(.target==$t and .key==$k)] | last | .prev_value // empty' \
        "$AUDIT_PATH" 2>/dev/null || true)"
    restore_hint "$prev"
}

# --- Arg parsing ---
[[ $# -eq 0 ]] && die "no command. Usage: --requester <id> set --target <t> --key <K> --value <V> [--reason ..]"

CMD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --requester) REQUESTER_RAW="$2"; shift 2 ;;
        --target)    TARGET="$2"; shift 2 ;;
        --key)       KEY="$2"; shift 2 ;;
        --value)     VALUE="$2"; VALUE_SET=1; shift 2 ;;
        --reason)    REASON="$2"; shift 2 ;;
        --confirmed-by)    CONFIRMED_BY="$2"; shift 2 ;;
        --approval-msg-id) APPROVAL_MSG_ID="$2"; shift 2 ;;
        set|rollback|resolve-email|help) CMD="$1"; shift ;;
        resolve-email-arg) shift ;;
        *)
            if [[ "$CMD" == "resolve-email" && -z "$REQUESTER_RAW" ]]; then
                REQUESTER_RAW="$1"; shift
            else
                die "unknown argument: $1"
            fi
            ;;
    esac
done

[[ -n "$REQUESTER_RAW" ]] && REQUESTER_EMAIL="$(resolve_slack_to_email "$REQUESTER_RAW" || true)"

case "$CMD" in
    set)           cmd_set ;;
    rollback)      cmd_rollback ;;
    resolve-email) echo "$REQUESTER_EMAIL" ;;
    help|"")       sed -n '2,30p' "$0" ;;
    *)             die "unknown command: $CMD" ;;
esac
