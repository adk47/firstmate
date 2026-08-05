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
#   bash devops-set-env.sh --requester <slack_id|email> [--env dev|prod] \
#        set --target <service> --key <KEY> --value <VALUE> [--reason "..."] \
#        [--confirmed-by <handle> --approval-msg-id <slack_ts>]
#   bash devops-set-env.sh --requester <id> rollback --target <service> --key <KEY>
#   bash devops-set-env.sh resolve-email <slack_id>
#
# --env defaults to 'prod' (fail-safe). In 'dev', an authorized dev requester
# (config/dev-envset-requesters.txt) may set ANY dev env var — secret-shaped
# included — with no green-light; the value is still redacted + audited.
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

# --- DEV-scope config (used only when --env dev) ---
# DEV is intentionally broader than prod (Nick's directive 2026-07-17): the dev
# requesters below may set ANY dev env var — secret or not — with no per-change
# human approval. Containment is the backend's muso-dev scope + the audit trail,
# not a blocklist. Both files are fail-closed if missing.
DEV_ENVSET_REQUESTERS_PATH="${DEV_ENVSET_REQUESTERS_PATH:-${SCRIPT_DIR}/../config/dev-envset-requesters.txt}"
DEV_TARGET_ALLOWLIST_PATH="${DEV_TARGET_ALLOWLIST_PATH:-${SCRIPT_DIR}/../config/dev-target-allowlist.txt}"

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

# --- DEV backend (Vault KV v2 merge-patch) ---
# Verified on node-8 (2026-07-17): dev env lives in Vault KV v2 at
# `secret/data/k8s/<ns>/<name>` and is ESO-synced (30s) to the k8s Secret, with
# stakater/reloader auto-restarting the consuming pods. So the DURABLE dev write
# is a Vault merge-patch (mirrors `vault kv patch`); a `kubectl patch secret`
# would be reverted by ESO within 30s. node-8 has NO vault CLI, so we use curl
# against the HTTP API. Fail-closed until an operator provides a reachable Vault
# address + a token/AppRole scoped to `secret/data/k8s/muso-dev/*` — Vault's
# in-cluster svc address is NOT reachable from node-8's host (see SKILL.md).
DEVOPS_DEV_VAULT_ADDR="${DEVOPS_DEV_VAULT_ADDR:-${VAULT_ADDR:-}}"
DEVOPS_DEV_VAULT_TOKEN="${DEVOPS_DEV_VAULT_TOKEN:-${VAULT_TOKEN:-}}"
DEVOPS_DEV_VAULT_MOUNT="${DEVOPS_DEV_VAULT_MOUNT:-secret}"   # KV v2 mount
DEVOPS_DEV_VAULT_PREFIX="${DEVOPS_DEV_VAULT_PREFIX:-k8s}"    # key prefix; path = <mount>/data/<prefix>/<target>

# --- Flags ---
REQUESTER_RAW=""; REQUESTER_EMAIL=""
TARGET=""; KEY=""; VALUE=""; VALUE_SET=0; REASON=""
CONFIRMED_BY=""; APPROVAL_MSG_ID=""
BLOCKLIST_OVERRIDDEN=0   # set to 1 when a blocklisted key proceeds via a prod green-light
# Environment scope. Default 'prod' — an omitted --env NEVER applies dev's looser
# rules to a prod target (fail-safe). Set by --env dev|prod.
ENV_SCOPE="prod"
SECRET_SHAPED=0          # set to 1 when the key matches the secret-shaped blocklist (drives redaction)
DEV_SELF_SERVE=0         # set to 1 when a secret-shaped key proceeds via dev self-serve (no green-light)

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
        U02N2NP3H7F) echo "artem@muso.ai" ;;   # Artem (Mobile) — dev authority
        # Artem D (Dolobanko, U0ACHTYUULT, ex-DevOps Lead) has LEFT the company
        # (2026-07-30) and is deliberately absent from this map AND from
        # dev-envset-requesters.txt. Do not re-add him. U02N2NP3H7F above is the
        # only Artem now, so the old "two Artems" disambiguation no longer applies.
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

# Which requester / target list is active for the current --env scope.
# prod → the original (narrow) lists; dev → the broader dev lists.
active_requesters_path() {
    if [[ "$ENV_SCOPE" == "dev" ]]; then echo "$DEV_ENVSET_REQUESTERS_PATH"; else echo "$ENVSET_REQUESTERS_PATH"; fi
}
active_target_allowlist_path() {
    if [[ "$ENV_SCOPE" == "dev" ]]; then echo "$DEV_TARGET_ALLOWLIST_PATH"; else echo "$TARGET_ALLOWLIST_PATH"; fi
}

# --- Gate: requester authorized (DevOps-tier humans only) ---
# Fail-closed: a missing allowlist refuses everyone. The active list depends on
# --env: prod uses the narrow envset-requesters; dev uses dev-envset-requesters.
authorize_requester() {
    local path; path="$(active_requesters_path)"
    local lines
    if ! lines="$(read_config_lines "$path")"; then
        echo "DEVOPS_ENVSET_CONFIG_MISSING: requester allowlist ${path} is missing — refusing every set until it is restored." >&2
        return 1
    fi
    local want; want="$(lc "$REQUESTER_EMAIL")"
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$(lc "$line")" == "$want" ]] && return 0
    done <<< "$lines"
    echo "DEVOPS_ENVSET_REQUESTER_DENIED: '${REQUESTER_EMAIL}' is not in the env=${ENV_SCOPE} requester allowlist (${path}). Only authorized humans may drive ${ENV_SCOPE} env changes." >&2
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

# --- Gate: target allow-listed (fail-closed) ---
# prod: EXACT match against target-allowlist.txt (unchanged).
# dev:  GLOB match against dev-target-allowlist.txt (e.g. `muso-dev/*`) — dev is
#       intentionally permissive; real blast-radius containment is the backend,
#       which hard-pins the muso-dev scope so a dev set can never reach prod.
is_allowed_target() {
    local path; path="$(active_target_allowlist_path)"
    local lines
    if ! lines="$(read_config_lines "$path")"; then
        echo "DEVOPS_ENVSET_CONFIG_MISSING: target allowlist ${path} is missing — refusing every set until it is restored." >&2
        return 1
    fi
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$ENV_SCOPE" == "dev" ]]; then
            # RHS intentionally unquoted so glob `*` is active.
            # shellcheck disable=SC2053
            [[ "$TARGET" == $line ]] && return 0
        else
            [[ "$line" == "$TARGET" ]] && return 0
        fi
    done <<< "$lines"
    echo "DEVOPS_ENVSET_TARGET_DENIED: target '${TARGET}' is not in the env=${ENV_SCOPE} allowlist (${path})." >&2
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
    lines="$(read_config_lines "$(active_requesters_path)")" || return 1
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
    --confirmed-by <handle>   (one of: $(read_config_lines "$(active_requesters_path)" 2>/dev/null | tr '\n' ' '))
    --approval-msg-id <slack_ts>
EOF
        return 1
    fi
    if ! requester_is_approver "$CONFIRMED_BY"; then
        echo "DEVOPS_ENVSET_RATE_APPROVAL_INVALID: --confirmed-by '${CONFIRMED_BY}' is not in $(active_requesters_path)." >&2
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
    # Redact secret-shaped VALUES from the audit JSONL regardless of the path
    # that let them through (a prod green-light OR dev self-serve) — the record
    # still captures WHO set WHICH key on WHAT target + env, just not the material.
    local prev_logged="$prev" new_logged="$VALUE"
    if [[ "$SECRET_SHAPED" == "1" ]]; then
        prev_logged="$REDACTED_MARKER"
        new_logged="$REDACTED_MARKER"
    fi
    local line
    line="$(jq -n -c \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg env "$ENV_SCOPE" \
        --arg requester "$REQUESTER_EMAIL" \
        --arg target "$TARGET" --arg key "$KEY" \
        --arg prev "$prev_logged" --arg new "$new_logged" \
        --arg reason "$REASON" --arg confirmed_by "$CONFIRMED_BY" \
        --arg approval_msg_id "$APPROVAL_MSG_ID" \
        --arg backend "$DEVOPS_ENVSET_BACKEND" --arg result "$result" \
        --argjson dry_run "$([[ "$OPS_DRY_RUN" == "1" ]] && echo true || echo false)" \
        --argjson blocklist_override "$([[ "$BLOCKLIST_OVERRIDDEN" == "1" ]] && echo true || echo false)" \
        --argjson dev_self_serve "$([[ "$DEV_SELF_SERVE" == "1" ]] && echo true || echo false)" \
        '{ts:$ts, env:$env, requester:$requester, target:$target, key:$key,
          prev_value:$prev, new_value:$new, reason:$reason,
          blocklist_override:$blocklist_override, dev_self_serve:$dev_self_serve,
          confirmed_by:(if $confirmed_by=="" then null else $confirmed_by end),
          approval_msg_id:(if $approval_msg_id=="" then null else $approval_msg_id end),
          backend:$backend, dry_run:$dry_run, result:$result}' 2>/dev/null)" \
        || { echo "DEVOPS_ENVSET_AUDIT_UNWRITABLE: jq failed to build audit line — refusing the set." >&2; return 1; }
    printf '%s\n' "$line" >> "$AUDIT_PATH" 2>/dev/null \
        || { echo "DEVOPS_ENVSET_AUDIT_UNWRITABLE: append to ${AUDIT_PATH} failed — refusing the set." >&2; return 1; }
    return 0
}

# --- DEV Vault backend (KV v2 merge-patch via curl) ---
# Hard-scoped to the dev namespaces so a dev set can NEVER escape muso-dev, even
# if a target somehow passed the allowlist. Path: <mount>/data/<prefix>/<target>.
dev_vault_scope_ok() {
    # Full-target validation (NOT a prefix glob): <namespace>/<name>, where the
    # namespace is a pinned dev namespace and <name> is a single clean segment.
    # A bare `muso-dev/*` glob also matches traversal (muso-dev/../../x), extra
    # path segments, and reserved chars (?, #, %) that curl/Vault URL
    # normalization could re-interpret to ESCAPE the muso-dev scope. The strict
    # regex is what actually makes the "can never escape muso-dev" claim true.
    if [[ "$TARGET" =~ ^(muso-dev|muso-chat-dev)/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        return 0
    fi
    echo "DEVOPS_ENVSET_DEV_SCOPE_VIOLATION: target '${TARGET}' is outside the dev Vault scope or is not a clean <namespace>/<name> segment (allowed: muso-dev/<name>, muso-chat-dev/<name>; no traversal, extra path segments, or reserved characters). Refusing." >&2
    return 1
}
dev_vault_url() { printf '%s/v1/%s/data/%s/%s' "${DEVOPS_DEV_VAULT_ADDR%/}" "$DEVOPS_DEV_VAULT_MOUNT" "$DEVOPS_DEV_VAULT_PREFIX" "$TARGET"; }
dev_vault_configured() { [[ -n "$DEVOPS_DEV_VAULT_ADDR" && -n "$DEVOPS_DEV_VAULT_TOKEN" ]]; }

# Secrets must NEVER travel through curl's argv (visible in `ps` /
# `/proc/<pid>/cmdline`) NOR through a temp file (a mid-call kill could orphan a
# token-bearing file on disk). Both the Vault token and the write payload are fed
# to curl via `--config -` — a curl config read from STDIN — so nothing sensitive
# is ever an argument or a file, and there is nothing to clean up on a crash.
# This helper escapes a value for a curl-config double-quoted string
# (backslash first, then double-quote).
_curl_cfg_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# Reads the current value of $KEY so the audit + rollback hint capture a
# TRUSTWORTHY prior value. Fail-closed: only a 200 body proving the key present
# (or a 404 proving the secret absent) yields a value/"" with success. A
# transport error, 403, or malformed body returns NON-ZERO so cmd_set refuses
# the set rather than fabricating "no prior value" — which would silently corrupt
# the audit trail and make the rollback hint claim there was nothing to restore.
dev_vault_read() {
    dev_vault_configured || { echo ""; return 0; }
    # Never even READ outside the dev scope (the write refuses loudly below).
    dev_vault_scope_ok 2>/dev/null || { echo ""; return 0; }
    # Token via `curl --config -` (config on stdin) — never argv, never a file.
    local resp http body rc=0
    resp="$(printf 'header = "X-Vault-Token: %s"\n' "$(_curl_cfg_escape "$DEVOPS_DEV_VAULT_TOKEN")" \
        | curl -sS --config - -w '\n%{http_code}' "$(dev_vault_url)" 2>/dev/null)" || rc=$?
    [[ $rc -eq 0 ]] \
        || { echo "DEVOPS_ENVSET_DEV_VAULT_READ_FAILED: transport error reading ${TARGET}; refusing the set to keep the audit/rollback prev-value trustworthy." >&2; return 1; }
    http="${resp##*$'\n'}"   # last line = %{http_code}
    body="${resp%$'\n'*}"    # everything before it = response body
    case "$http" in
        200) : ;;                    # parse the body below
        404) echo ""; return 0 ;;    # KV v2: secret absent → genuinely no prior value
        403) echo "DEVOPS_ENVSET_DEV_VAULT_READ_FAILED: HTTP 403 reading ${TARGET} (token lacks 'read'); refusing the set to keep the audit/rollback prev-value trustworthy." >&2; return 1 ;;
        *)   echo "DEVOPS_ENVSET_DEV_VAULT_READ_FAILED: unexpected HTTP '${http}' reading ${TARGET}; refusing the set." >&2; return 1 ;;
    esac
    # A 200 must be a well-formed KV v2 doc: `.data.data` MUST be an object. When
    # it is, an ABSENT key is a legitimate empty prior value (rc 0). When the
    # shape is wrong (`{}`, `{"data":{}}`, `.data.data` null/string, …) or the
    # body is not JSON, jq exits non-zero and we FAIL CLOSED — a bad response
    # must never be mistaken for "no prior value" (that recreates the very
    # audit/rollback corruption this read-integrity path exists to prevent).
    local val
    val="$(printf '%s' "$body" | jq -r --arg k "$KEY" \
        'if (.data.data | type) == "object" then (.data.data[$k] // "") else halt_error(1) end' 2>/dev/null)" \
        || { echo "DEVOPS_ENVSET_DEV_VAULT_READ_FAILED: 200 response for ${TARGET} is not a valid KV v2 secret (missing .data.data object) or not JSON; refusing the set." >&2; return 1; }
    printf '%s' "$val"
    return 0
}

dev_vault_write() {
    dev_vault_scope_ok || return 1
    if ! dev_vault_configured; then
        echo "DEVOPS_ENVSET_DEV_VAULT_UNCONFIGURED: dev writes go to Vault KV v2 (merge-patch at ${DEVOPS_DEV_VAULT_MOUNT}/data/${DEVOPS_DEV_VAULT_PREFIX}/${TARGET}; ESO syncs it to the k8s Secret and stakater/reloader restarts the pods). But no reachable+authorized Vault is configured here. Provision DEVOPS_DEV_VAULT_ADDR (a node-8-reachable Vault endpoint) + DEVOPS_DEV_VAULT_TOKEN (a token/AppRole scoped to ${DEVOPS_DEV_VAULT_MOUNT}/data/${DEVOPS_DEV_VAULT_PREFIX}/muso-dev/* patch + .../metadata/...). See SKILL.md 'DEV go-live'." >&2
        return 1
    fi
    # KV v2 merge-patch: preserves the other keys in the secret (like `vault kv patch`).
    local body; body="$(jq -nc --arg k "$KEY" --arg v "$VALUE" '{data:{($k):$v}}')" \
        || { echo "DEVOPS_ENVSET_DEV_VAULT_WRITE_FAILED: could not build request body." >&2; return 1; }
    # Token AND secret payload both via `curl --config -` (config on stdin) —
    # never argv, never a temp file.
    local http rc=0
    http="$( { printf 'header = "X-Vault-Token: %s"\n' "$(_curl_cfg_escape "$DEVOPS_DEV_VAULT_TOKEN")"
               printf 'data-binary = "%s"\n' "$(_curl_cfg_escape "$body")"; } \
        | curl -sS -o /dev/null -w '%{http_code}' \
            -H 'Content-Type: application/merge-patch+json' \
            -X PATCH --config - "$(dev_vault_url)" 2>/dev/null)" || rc=$?
    [[ $rc -eq 0 ]] \
        || { echo "DEVOPS_ENVSET_DEV_VAULT_WRITE_FAILED: curl transport error to Vault." >&2; return 1; }
    case "$http" in
        200|204) return 0 ;;
        403) echo "DEVOPS_ENVSET_DEV_VAULT_WRITE_FAILED: HTTP 403 — the Vault token lacks 'patch' on ${DEVOPS_DEV_VAULT_MOUNT}/data/${DEVOPS_DEV_VAULT_PREFIX}/${TARGET}." >&2; return 1 ;;
        404) echo "DEVOPS_ENVSET_DEV_VAULT_WRITE_FAILED: HTTP 404 — secret ${DEVOPS_DEV_VAULT_PREFIX}/${TARGET} does not exist (KV v2 merge-patch requires it to exist first)." >&2; return 1 ;;
        *)   echo "DEVOPS_ENVSET_DEV_VAULT_WRITE_FAILED: unexpected HTTP ${http} from Vault." >&2; return 1 ;;
    esac
}

# --- Backend (stub for tests; DEV Vault wired; PROD Phase-0-pending) ---
backend_read_current() {
    case "$DEVOPS_ENVSET_BACKEND" in
        stub)
            [[ -f "${DEVOPS_ENVSET_STUB_STORE:-}" ]] || { echo ""; return 0; }
            # last value wins; print empty if absent
            grep -E "^${KEY}=" "$DEVOPS_ENVSET_STUB_STORE" 2>/dev/null | tail -1 | sed "s/^${KEY}=//" || echo ""
            ;;
        vault)
            # Propagate dev_vault_read's exit so a failed/untrusted read fails closed.
            if [[ "$ENV_SCOPE" == "dev" ]]; then dev_vault_read; return $?; fi
            echo "" ;;  # PROD Vault: real read pinned in Phase-0
        kubectl)
            echo "" ;;  # PROD: real read pinned on node-8 against H-DevOps
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
        vault)
            # DEV Vault path is WIRED (fail-closed without creds). PROD Vault stays
            # Phase-0-pending (scoped credential + write command still to pin).
            if [[ "$ENV_SCOPE" == "dev" ]]; then
                dev_vault_write; return $?
            fi
            echo "DEVOPS_ENVSET_BACKEND_NOT_PINNED: backend='vault' env='prod' is not yet wired. Phase-0 verification on node-8 (against H-DevOps) must pin the exact prod write command, and Artem/Aaron must provision the scoped Vault policy this authenticates as. Refusing to guess a prod write." >&2
            return 1 ;;
        kubectl)
            echo "DEVOPS_ENVSET_BACKEND_NOT_PINNED: backend='kubectl' is not yet wired (and for dev-synced secrets kubectl is non-durable — ESO reverts it). Refusing." >&2
            return 1 ;;
        *)
            echo "DEVOPS_ENVSET_BACKEND_UNSET: set DEVOPS_ENVSET_BACKEND (stub for tests; vault once creds+endpoint are provisioned). Refusing." >&2
            return 1 ;;
    esac
}

restore_hint() {
    local prev="$1"
    # Never echo a secret-shaped value: at set-time SECRET_SHAPED==1 (a prod
    # green-light OR dev self-serve); at rollback-time the audit log already
    # holds the redaction marker (the real prior value was never persisted).
    if [[ "$SECRET_SHAPED" == "1" || "$prev" == "$REDACTED_MARKER" ]]; then
        echo "↩ rollback: ${KEY} is secret-shaped; its prior value is not echoed here. Roll it back via the secret-management path (Vault/K8s), not this wrapper."
    elif [[ -z "$prev" ]]; then
        echo "↩ rollback: ${KEY} had NO prior value on ${TARGET}; unset it to revert."
    else
        # printf %q shell-escapes the prior value so the printed command is safe
        # to paste even if it contains quotes, newlines, or metacharacters.
        local prev_q; prev_q="$(printf '%q' "$prev")"
        echo "↩ rollback: bash devops-set-env.sh --requester <id> --env ${ENV_SCOPE} set --target ${TARGET} --key ${KEY} --value ${prev_q} --reason 'rollback'"
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
        SECRET_SHAPED=1
        if [[ "$ENV_SCOPE" == "dev" ]]; then
            # DEV self-serve (Nick's directive 2026-07-17): a dev-authorized
            # requester may set a secret-shaped key with NO green-light. The value
            # is still redacted in the audit, and the set is logged + rate-capped
            # + rollback-hinted. Containment is the backend's muso-dev scope.
            DEV_SELF_SERVE=1
        else
            # PROD: a blocklisted key is NOT a dead-end, but proceeds ONLY with an
            # explicit human green-light (--confirmed-by an override-approver +
            # --approval-msg-id).
            enforce_blocklist_override || exit 4
            BLOCKLIST_OVERRIDDEN=1
        fi
    fi

    is_allowed_target || exit 5
    enforce_rate_gate || exit 6

    # Fail-closed: a read we can't trust (transport/403/malformed) must refuse the
    # set, not proceed with a fabricated empty prev that would corrupt the audit +
    # rollback hint. `local prev` is SPLIT from the assignment so the `||` actually
    # sees backend_read_current's exit (a `local prev=$(...)` masks it to 0).
    local prev
    prev="$(backend_read_current)" || exit 8

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
        echo "{\"dryRun\":true,\"env\":\"${ENV_SCOPE}\",\"target\":\"${TARGET}\",\"key\":\"${KEY}\",\"wouldHaveExecuted\":true}"
        restore_hint "$prev"
        return 0
    fi

    if backend_write; then
        echo "✅ set ${KEY} on ${TARGET} (env=${ENV_SCOPE}, backend=${DEVOPS_ENVSET_BACKEND})."
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
        --env)       ENV_SCOPE="$(lc "$2")"; shift 2 ;;
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

case "$ENV_SCOPE" in
    dev|prod) ;;
    *) die "invalid --env '${ENV_SCOPE}' (expected 'dev' or 'prod')" ;;
esac

[[ -n "$REQUESTER_RAW" ]] && REQUESTER_EMAIL="$(resolve_slack_to_email "$REQUESTER_RAW" || true)"

case "$CMD" in
    set)           cmd_set ;;
    rollback)      cmd_rollback ;;
    resolve-email) echo "$REQUESTER_EMAIL" ;;
    help|"")       sed -n '2,30p' "$0" ;;
    *)             die "unknown command: $CMD" ;;
esac
