#!/usr/bin/env bash
# claim-self.sh – Caroline gated "verify the customer's own pending profile claim".
#
# Architecture: this is the THIN bash boundary in front of the muso-cli
# capability gate. Unlike remove-credits.sh (which re-implements ownership in
# bash against the raw admin API), this wrapper delegates ownership + caps +
# server-side audit to `muso profiles claim-self --actor-identity <email>`:
#   - muso re-fetches the claim and refuses (exit 5, route_to_human) unless the
#     claim's workspace email equals --actor-identity;
#   - an already-processed claim is an idempotent no-op.
# The actor email is the conversation's verified Intercom author email, derived
# in-plugin from the trusted gateway session key (NOT a model arg), so the
# wrapper trusts the passed --actor-identity. The wrapper adds: a hydra-side
# audit line, an OPS_DRY_RUN kill switch, and the dry-run→apply surface.
#
# Invoked by the TS tool via `execFile bash <this> ...`.
#
# Required env (set on the edge gateway by the deploy unit):
#   muso on PATH (or MUSO_BIN), MUSO_ADMIN_EMAIL/MUSO_ADMIN_PASSWORD (muso auth),
#   MUSO_STATE_DIR (muso's caps + tier2 audit), MUSO_REQUESTER (or falls back to
#   MUSO_ADMIN_EMAIL) for muso's --requester.
#
# Required argv:
#   --claim-id <id>                the pending claim to verify
#   --actor-identity <email>       verified Intercom contact email (the owner)
# Optional argv:
#   --intercom-conv-id <id>        for the hydra audit line
#   --apply                        real apply; default is dry-run
#
# Audit log: /var/log/openclaw/customer-profile-claim.jsonl
# Output: a single JSON object on stdout (always); exit 0.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

AUDIT_LOG="${PROFILE_CLAIM_AUDIT_LOG:-/var/log/openclaw/customer-profile-claim.jsonl}"
MUSO_BIN="${MUSO_BIN:-muso}"

_now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

_emit_error() {
  local error="$1" detail="${2:-}"
  jq -n -c --arg error "$error" --arg detail "$detail" \
    '{ok:false, error:$error, detail:(if $detail=="" then null else $detail end)}'
}

_audit_probe() {
  local d; d="$(dirname "$AUDIT_LOG")"
  mkdir -p "$d" 2>/dev/null || return 1
  touch "$AUDIT_LOG" 2>/dev/null || return 1
  printf '' >> "$AUDIT_LOG" 2>/dev/null || return 1
  return 0
}

_audit() {
  local status="$1" detail="${2:-}" rc="${3:-}"
  jq -n -c \
    --arg ts "$(_now_iso)" --arg claim_id "$claim_id" \
    --arg actor "$actor_email_lc" --arg conv "$intercom_conv_id" \
    --arg mode "$mode" --arg status "$status" --arg detail "$detail" --arg rc "$rc" \
    '{ts:$ts, tool:"profiles_claim_self", claim_id:$claim_id, actor_identity:$actor,
      intercom_conv_id:(if $conv=="" then null else $conv end), mode:$mode, status:$status,
      detail:(if $detail=="" then null else $detail end),
      muso_exit:(if $rc=="" then null else ($rc|tonumber? // $rc) end)}' \
    >> "$AUDIT_LOG" 2>/dev/null || echo "WARN: could not append to $AUDIT_LOG; audit line LOST" >&2
}

# --- argv ---
claim_id=""; actor_email=""; intercom_conv_id=""; apply=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --claim-id)        claim_id="${2:-}"; shift 2 ;;
    --actor-identity)  actor_email="${2:-}"; shift 2 ;;
    --intercom-conv-id) intercom_conv_id="${2:-}"; shift 2 ;;
    --apply)           apply=1; shift ;;
    --dry-run)         apply=0; shift ;;
    -h|--help) echo "claim-self.sh --claim-id <id> --actor-identity <email> [--intercom-conv-id <id>] [--apply]"; exit 0 ;;
    *) _emit_error "unknown_arg" "$1"; exit 0 ;;
  esac
done
mode="dry-run"; (( apply == 1 )) && mode="apply"

# --- validate ---
[[ -n "$claim_id"    ]] || { _emit_error "missing_arg" "--claim-id"; exit 0; }
[[ -n "$actor_email" ]] || { _emit_error "missing_arg" "--actor-identity"; exit 0; }
[[ "$claim_id" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || { _emit_error "invalid_claim_id" "redacted"; exit 0; }
[[ "$actor_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { _emit_error "invalid_actor_identity" "redacted"; exit 0; }
if [[ -n "$intercom_conv_id" ]] && ! [[ "$intercom_conv_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
  _emit_error "invalid_intercom_conv_id" "redacted"; exit 0
fi
actor_email_lc="$(printf %s "$actor_email" | tr '[:upper:]' '[:lower:]')"

# Defense-in-depth kill switch.
if [[ "${OPS_DRY_RUN:-0}" == "1" ]]; then _emit_error "ops_dry_run_set" "OPS_DRY_RUN=1; refusing"; exit 0; fi
# Fail-closed audit.
_audit_probe || { _emit_error "audit_unwritable" "cannot write to $AUDIT_LOG; refusing"; exit 0; }

requester="${MUSO_REQUESTER:-${MUSO_ADMIN_EMAIL:-}}"
[[ -n "$requester" ]] || { _audit "refused_no_requester"; _emit_error "no_requester" "MUSO_REQUESTER/MUSO_ADMIN_EMAIL unset"; exit 0; }
command -v "$MUSO_BIN" >/dev/null 2>&1 || { _audit "refused_no_muso"; _emit_error "muso_unavailable" "muso binary not found on edge"; exit 0; }

# --- delegate to the muso-cli capability gate ---
muso_args=(profiles claim-self --json --actor-identity "$actor_email_lc" --requester "$requester" --claim-id "$claim_id")
(( apply == 0 )) && muso_args+=(--dry-run)

# Run muso EXACTLY ONCE (a second run would double-apply): stdout → var,
# stderr → temp file, exit code preserved.
set +e
_err_file="$(mktemp)"
muso_out="$("$MUSO_BIN" "${muso_args[@]}" 2>"$_err_file")"
rc=$?
muso_err="$(cat "$_err_file" 2>/dev/null || true)"
rm -f "$_err_file"
set -e

if [[ $rc -eq 0 ]]; then
  # Dry-run (apply=false): muso's gate short-circuits and emits the dryRunResult
  # envelope ({dryRun,method,url,body,note}), NOT a result struct – surface the
  # human note + resolved body as the preview, never a bogus status:"unknown".
  if [[ "$(printf %s "$muso_out" | jq -r 'if .dryRun==true then "y" else "n" end' 2>/dev/null || echo n)" == "y" ]]; then
    note="$(printf %s "$muso_out" | jq -r '.note // empty' 2>/dev/null || true)"
    body_preview="$(printf %s "$muso_out" | jq -c '.body // {}' 2>/dev/null || echo '{}')"
    _audit "dry_run" "$note" "$rc"
    jq -n -c --arg note "$note" --argjson preview "$body_preview" \
      '{ok:true, mode:"dry-run", status:"dry_run", note:(if $note=="" then null else $note end), preview:$preview}'
    exit 0
  fi
  status="$(printf %s "$muso_out" | jq -r '.status // "unknown"' 2>/dev/null || echo unknown)"
  profile_id="$(printf %s "$muso_out" | jq -r '.profileId // .profile_id // empty' 2>/dev/null || true)"
  _audit "$status" "" "$rc"
  jq -n -c --arg mode "$mode" --arg claim_id "$claim_id" --arg profile_id "$profile_id" --arg status "$status" \
    '{ok:true, mode:$mode, claim_id:$claim_id, profile_id:(if $profile_id=="" then null else $profile_id end), status:$status}'
  exit 0
fi

# Non-zero: muso refused (exit 5 = capability route_to_human) or failed.
detail="$(printf %s "$muso_err" | tr -d '\r' | head -c 300)"
if [[ $rc -eq 5 ]]; then
  _audit "refused_route_to_human" "$detail" "$rc"
  jq -n -c --arg detail "$detail" '{ok:false, error:"route_to_human", detail:(if $detail=="" then null else $detail end)}'
else
  _audit "muso_failed" "$detail" "$rc"
  jq -n -c --arg detail "$detail" --arg rc "$rc" '{ok:false, error:"muso_failed", detail:(if $detail=="" then null else $detail end), exit_code:($rc|tonumber? // $rc)}'
fi
exit 0
