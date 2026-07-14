#!/usr/bin/env bash
# consolidate.sh – Caroline gated "consolidate the customer's own duplicate
# profiles into the profile they own" (APPROVAL-tier write).
#
# Architecture: this is the THIN bash boundary in front of the muso-cli
# capability gate. Like claim-self.sh, this wrapper delegates ownership + caps +
# server-side audit to `muso profiles consolidate --actor-identity <email>`:
#   - muso re-fetches the survivor + duplicates and refuses (exit 5,
#     route_to_human) unless the survivor is owned by --actor-identity and the
#     merge is permitted.
# The actor email is the conversation's verified Intercom author email, derived
# in-plugin from the trusted gateway session key (NOT a model arg), so the
# wrapper trusts the passed --actor-identity. The wrapper adds: a hydra-side
# audit line, an OPS_DRY_RUN kill switch, and the dry-run→apply surface.
#
# This is an APPROVAL-tier muso verb: it must carry --yes --confirmed-by
# --approval-ref. The approver is the ops/capability approver from
# ${MUSO_CAPABILITY_APPROVER} (fail closed with no_approver if unset); the
# approval-ref is the intercom-conv-id (the audit trail), so --intercom-conv-id
# is REQUIRED for this verb.
#
# Invoked by the TS tool via `execFile bash <this> ...`.
#
# Required env (set on the edge gateway by the deploy unit):
#   muso on PATH (or MUSO_BIN), MUSO_ADMIN_EMAIL/MUSO_ADMIN_PASSWORD (muso auth),
#   MUSO_STATE_DIR (muso's caps + tier2 audit), MUSO_REQUESTER (or falls back to
#   MUSO_ADMIN_EMAIL) for muso's --requester, MUSO_CAPABILITY_APPROVER for the
#   approval-tier --confirmed-by.
#
# Required argv:
#   --into <uuid>                  the survivor profile (the owner's profile)
#   --from <uuid>                  a duplicate to fold in (repeatable, 1+)
#   --actor-identity <email>       verified Intercom contact email (the owner)
#   --intercom-conv-id <id>        the approval-ref (REQUIRED for this verb)
# Optional argv:
#   --apply                        real apply; default is dry-run
#   --attested-msg <part_id>       Intercom part id of the CUSTOMER's own
#                                  confirmation message in this conversation;
#                                  muso verifies its provenance (author =
#                                  contact = actor, recent) and may then merge
#                                  an unclaimed, small duplicate whose name it
#                                  could not corroborate. Never model-invented:
#                                  the plugin resolves it from the conversation.
#
# Audit log: /var/log/openclaw/customer-profile-consolidate.jsonl
# Output: a single JSON object on stdout (always); exit 0.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

AUDIT_LOG="${PROFILE_CONSOLIDATE_AUDIT_LOG:-/var/log/openclaw/customer-profile-consolidate.jsonl}"
MUSO_BIN="${MUSO_BIN:-muso}"
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

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
    --arg ts "$(_now_iso)" --arg survivor "$survivor_id" --arg dups "${dup_ids[*]}" \
    --arg actor "$actor_email_lc" --arg conv "$intercom_conv_id" --arg attested "$attested_msg" \
    --arg mode "$mode" --arg status "$status" --arg detail "$detail" --arg rc "$rc" \
    '{ts:$ts, tool:"profiles_consolidate", survivor_id:$survivor, dup_ids:($dups|split(" ")|map(select(length>0))),
      actor_identity:$actor, intercom_conv_id:(if $conv=="" then null else $conv end),
      attested_msg:(if $attested=="" then null else $attested end), mode:$mode, status:$status,
      detail:(if $detail=="" then null else $detail end),
      muso_exit:(if $rc=="" then null else ($rc|tonumber? // $rc) end)}' \
    >> "$AUDIT_LOG" 2>/dev/null || echo "WARN: could not append to $AUDIT_LOG; audit line LOST" >&2
}

# --- argv ---
survivor_id=""; actor_email=""; intercom_conv_id=""; apply=0; attested_msg=""
dup_ids=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --into)            survivor_id="${2:-}"; shift 2 ;;
    --from)            dup_ids+=("${2:-}"); shift 2 ;;
    --actor-identity)  actor_email="${2:-}"; shift 2 ;;
    --intercom-conv-id) intercom_conv_id="${2:-}"; shift 2 ;;
    --attested-msg)    attested_msg="${2:-}"; shift 2 ;;
    --apply)           apply=1; shift ;;
    --dry-run)         apply=0; shift ;;
    -h|--help) echo "consolidate.sh --into <uuid> --from <uuid> [--from <uuid>...] --actor-identity <email> --intercom-conv-id <id> [--attested-msg <part_id>] [--apply]"; exit 0 ;;
    *) _emit_error "unknown_arg" "$1"; exit 0 ;;
  esac
done
mode="dry-run"; (( apply == 1 )) && mode="apply"

# --- validate ---
[[ -n "$survivor_id"  ]] || { _emit_error "missing_arg" "--into"; exit 0; }
[[ ${#dup_ids[@]} -gt 0 ]] || { _emit_error "missing_arg" "--from"; exit 0; }
[[ -n "$actor_email"  ]] || { _emit_error "missing_arg" "--actor-identity"; exit 0; }
[[ -n "$intercom_conv_id" ]] || { _emit_error "missing_arg" "--intercom-conv-id"; exit 0; }
[[ "$survivor_id" =~ $UUID_RE ]] || { _emit_error "invalid_survivor_id" "redacted"; exit 0; }
for _d in "${dup_ids[@]}"; do
  [[ "$_d" =~ $UUID_RE ]] || { _emit_error "invalid_dup_id" "redacted"; exit 0; }
done
[[ "$actor_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { _emit_error "invalid_actor_identity" "redacted"; exit 0; }
[[ "$intercom_conv_id" =~ ^[A-Za-z0-9_-]+$ ]] || { _emit_error "invalid_intercom_conv_id" "redacted"; exit 0; }
[[ -z "$attested_msg" || "$attested_msg" =~ ^[A-Za-z0-9_-]+$ ]] || { _emit_error "invalid_attested_msg" "redacted"; exit 0; }
actor_email_lc="$(printf %s "$actor_email" | tr '[:upper:]' '[:lower:]')"

# Defense-in-depth kill switch.
if [[ "${OPS_DRY_RUN:-0}" == "1" ]]; then _emit_error "ops_dry_run_set" "OPS_DRY_RUN=1; refusing"; exit 0; fi
# Fail-closed audit.
_audit_probe || { _emit_error "audit_unwritable" "cannot write to $AUDIT_LOG; refusing"; exit 0; }

requester="${MUSO_REQUESTER:-${MUSO_ADMIN_EMAIL:-}}"
[[ -n "$requester" ]] || { _audit "refused_no_requester"; _emit_error "no_requester" "MUSO_REQUESTER/MUSO_ADMIN_EMAIL unset"; exit 0; }
# APPROVAL-tier: the capability approver is mandatory (fail closed).
approver="${MUSO_CAPABILITY_APPROVER:-}"
[[ -n "$approver" ]] || { _audit "refused_no_approver"; _emit_error "no_approver" "MUSO_CAPABILITY_APPROVER unset"; exit 0; }
command -v "$MUSO_BIN" >/dev/null 2>&1 || { _audit "refused_no_muso"; _emit_error "muso_unavailable" "muso binary not found on edge"; exit 0; }

# --- delegate to the muso-cli capability gate (APPROVAL-tier verb) ---
muso_args=(profiles consolidate --json --actor-identity "$actor_email_lc" --requester "$requester" --into "$survivor_id")
for _d in "${dup_ids[@]}"; do muso_args+=(--from "$_d"); done
muso_args+=(--yes --confirmed-by "$approver" --approval-ref "$intercom_conv_id")
# The attestation part id rides the SAME conversation as the approval-ref; the
# muso gate independently re-verifies its provenance (author, binding, age).
[[ -n "$attested_msg" ]] && muso_args+=(--attested-msg "$attested_msg")
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
  out_survivor="$(printf %s "$muso_out" | jq -r '.survivor // .survivorId // empty' 2>/dev/null || true)"
  _audit "$status" "" "$rc"
  jq -n -c --arg mode "$mode" --arg survivor "${out_survivor:-$survivor_id}" --arg status "$status" --arg dups "${dup_ids[*]}" \
    '{ok:true, mode:$mode, survivor:$survivor, dup_ids:($dups|split(" ")|map(select(length>0))), status:$status}'
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
