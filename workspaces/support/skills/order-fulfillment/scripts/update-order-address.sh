#!/usr/bin/env bash
# update-order-address.sh – Caroline gated edit of a plaque/poster order's
# shipping recipient (name / phone / address), pushed to the print vendor (Prodigi).
#
# Architecture mirrors remove-credits.sh: the plugin's MusoAdminClient stays
# GET-only; this script is the single audit + ownership-enforcement surface for
# the destructive write. Invoked by the order_address_update tool via
# `execFile bash <this> ...` — fixed argv, no free-form params.
#
# The SECURITY boundary lives here:
#   1. Resolve the order server-side (GET) — the PUT findByPk needs the UUID,
#      so we resolve any ref (uuid / orderNumber / Prodigi id) to the canonical id.
#   2. Ownership: the requester's Intercom contact email (re-fetched server-side)
#      must equal BOTH the --customer-email passed AND the order's owner email.
#   3. Dry-run-before-apply: an apply requires a matching `would_update` audit row
#      (same order + same proposed body) from the last 15 minutes.
# Address *content* validation is authoritative in the TS dispatcher
# (validateProdigiAddress); a light required-field/40-char check here is
# defense-in-depth.
#
# Required env (set by the openclaw gateway unit):
#   MUSO_API_URL, MUSO_ADMIN_EMAIL, MUSO_ADMIN_PASSWORD  (used by muso-admin-api.sh)
#   MUSOAI_INTERCOM_TOKEN          required whenever --intercom-conv-id is passed
#                                  (always required under --apply)
#
# Required argv:
#   --order-ref <ref>              Order UUID, order number, or Prodigi order id
#   --customer-email <email>       Verified Intercom contact email (the order owner)
#   --body-file <path>             JSON: { name, phoneNumber, email?, address:{stripe-shape},
#                                          taxId?, taxIdType? }
#                                  taxId/taxIdType (Mexico RFC/CURP) ride along
#                                  verbatim in the PUT body; the backend stores +
#                                  forwards them to Prodigi. No validation here —
#                                  the TS dispatcher (normalizeTaxId) is authoritative.
#
# Optional argv:
#   --intercom-conv-id <id>        REQUIRED with --apply (cross-checks the email
#                                  against Intercom's stored author.email)
#   --apply                        Real apply. Default is dry-run (no PUT issued).
#
# Audit log: /var/log/openclaw/order-fulfillment.jsonl  (per-attempt JSONL)
# Output (stdout): a single JSON object (success or refusal). Always emits JSON.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# --- Constants ---
MAX_PER_CUSTOMER_PER_DAY="${OUA_MAX_PER_DAY:-10}"
AUDIT_LOG="${OUA_AUDIT_LOG:-/var/log/openclaw/order-fulfillment.jsonl}"
DRY_RUN_RECENCY_SECS="${OUA_DRY_RUN_RECENCY_SECS:-900}"
INTERCOM_API_BASE="${OUA_INTERCOM_API_BASE:-https://api.intercom.io}"
# Canonical source of the Prodigi address rules (40-char limit + required fields)
# is plugins/support-tools/src/order-address.ts (validateProdigiAddress), which the
# TS dispatcher enforces authoritatively. This bash check is defense-in-depth — keep
# the two in sync if Prodigi's limit ever changes.
PRODIGI_MAX_LINE=40

# --- Locate muso-admin-api.sh (same resolution order as remove-credits.sh) ---
MUSO_ADMIN_API="${MUSO_ADMIN_API_SCRIPT:-/opt/hydra/skills-all/muso-ops-admin/scripts/muso-admin-api.sh}"
if [[ ! -f "$MUSO_ADMIN_API" ]]; then
  MUSO_ADMIN_API="/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
fi
if [[ ! -f "$MUSO_ADMIN_API" ]]; then
  MUSO_ADMIN_API="$(find /opt -name muso-admin-api.sh -path '*/muso-ops-admin/*' 2>/dev/null | head -1 || true)"
fi

# --- Helpers ---
_now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

_emit_error() {
  local error="$1" detail="${2:-}"
  jq -n -c --arg error "$error" --arg detail "$detail" \
    '{ok:false, error:$error, detail:(if $detail=="" then null else $detail end)}'
}

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
  else shasum -a 256 | awk '{print $1}'; fi
}

_audit_probe() {
  local audit_dir
  audit_dir="$(dirname "$AUDIT_LOG")"
  mkdir -p "$audit_dir" 2>/dev/null || return 1
  touch "$AUDIT_LOG" 2>/dev/null || return 1
  printf '' >> "$AUDIT_LOG" 2>/dev/null || return 1
  return 0
}

# Append a JSONL audit row. Lenient mid-run (fail-closed gate is _audit_probe).
_audit() {
  local status="$1" reason="${2:-}" http_status="${3:-}"
  local line
  line=$(jq -n -c \
    --arg ts "$(_now_iso)" \
    --arg order_ref "$order_ref" \
    --arg order_id "${order_id_uuid:-}" \
    --arg requester_email "$customer_email_lc" \
    --arg intercom_conv_id "$intercom_conv_id" \
    --arg mode "$mode" \
    --arg status "$status" \
    --arg body_hash "${body_hash:-}" \
    --arg reason "$reason" \
    --arg http_status "$http_status" \
    '{
      ts: $ts,
      order_ref: $order_ref,
      order_id: (if $order_id == "" then null else $order_id end),
      requester_email: $requester_email,
      intercom_conv_id: (if $intercom_conv_id == "" then null else $intercom_conv_id end),
      mode: $mode,
      status: $status,
      body_hash: (if $body_hash == "" then null else $body_hash end),
      reason: (if $reason == "" then null else $reason end),
      http_status: (if $http_status == "" then null else ($http_status | tonumber? // $http_status) end)
    }')
  printf '%s\n' "$line" >> "$AUDIT_LOG" 2>/dev/null || {
    echo "WARN: could not append to $AUDIT_LOG; audit line LOST" >&2
  }
}

# Re-fetch the trusted contact email from Intercom (closes the message-text
# injection vector). Returns 0 if it matches the claimed email, 1 otherwise.
_verify_intercom_email() {
  local conv_id="$1" claimed_email_lc="$2"
  [[ -n "$conv_id" ]] || return 1
  [[ -n "${MUSOAI_INTERCOM_TOKEN:-}" ]] || {
    echo "WARN: MUSOAI_INTERCOM_TOKEN not set; cannot verify Intercom author.email" >&2
    return 1
  }
  local resp author_email_lc
  resp=$(curl -sS --max-time 10 \
    -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
    -H "Accept: application/json" \
    -H "Intercom-Version: 2.10" \
    "${INTERCOM_API_BASE}/conversations/${conv_id}?display_as=plaintext" 2>/dev/null) \
    || return 1
  author_email_lc=$(printf %s "$resp" | jq -r '.source.author.email // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [[ -n "$author_email_lc" ]] || return 1
  [[ "$author_email_lc" == "$claimed_email_lc" ]]
}

# Confirm a recent `would_update` row exists for this exact (order, requester, body).
_recent_dry_run_exists() {
  [[ -f "$AUDIT_LOG" ]] || return 1
  local cutoff_epoch
  cutoff_epoch=$(( $(date -u +%s) - DRY_RUN_RECENCY_SECS ))
  jq -e --arg order_ref "$order_ref" \
        --arg email "$customer_email_lc" \
        --arg body_hash "$body_hash" \
        --argjson cutoff "$cutoff_epoch" '
    select(.order_ref == $order_ref
           and .requester_email == $email
           and .body_hash == $body_hash
           and .status == "would_update"
           and (.ts | fromdateiso8601) >= $cutoff)
  ' "$AUDIT_LOG" >/dev/null 2>&1
}

# --- Argv parsing ---
order_ref=""
customer_email=""
body_file=""
intercom_conv_id=""
apply=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --order-ref)         order_ref="${2:-}"; shift 2 ;;
    --customer-email)    customer_email="${2:-}"; shift 2 ;;
    --body-file)         body_file="${2:-}"; shift 2 ;;
    --intercom-conv-id)  intercom_conv_id="${2:-}"; shift 2 ;;
    --apply)             apply=1; shift ;;
    --dry-run)           apply=0; shift ;;
    -h|--help)
      cat <<'EOF'
update-order-address.sh – Caroline gated order recipient/address edit

Required:
  --order-ref <ref>           Order UUID, order number, or Prodigi order id
  --customer-email <email>    Verified Intercom contact email (the order owner)
  --body-file <path>          JSON { name, phoneNumber, email?, address:{stripe-shape}, taxId?, taxIdType? }

Optional:
  --apply                     Real apply. Default is dry-run (no PUT).
  --intercom-conv-id <id>     REQUIRED with --apply.

Refuses on: order not found, owner mismatch, Intercom email mismatch, missing
required address fields, >40-char line, OPS_DRY_RUN=1, no recent dry-run (apply),
per-day cap. Output: JSON to stdout.
EOF
      exit 0 ;;
    *)
      _emit_error "unknown_arg" "$1"; exit 0 ;;
  esac
done

mode="dry-run"; (( apply == 1 )) && mode="apply"

# --- Arg validation ---
[[ -n "$order_ref"      ]] || { _emit_error "missing_arg" "--order-ref";      exit 0; }
[[ -n "$customer_email" ]] || { _emit_error "missing_arg" "--customer-email"; exit 0; }
[[ -n "$body_file"      ]] || { _emit_error "missing_arg" "--body-file";      exit 0; }
[[ -f "$body_file"      ]] || { _emit_error "body_file_missing" "$body_file"; exit 0; }

# order_ref is interpolated into the admin API path — restrict to a URL-safe set.
if ! [[ "$order_ref" =~ ^[A-Za-z0-9_-]+$ ]]; then
  _emit_error "invalid_order_ref" "redacted"; exit 0
fi
if ! [[ "$customer_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  _emit_error "invalid_customer_email" "redacted"; exit 0
fi
if [[ -n "$intercom_conv_id" ]] && ! [[ "$intercom_conv_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
  _emit_error "invalid_intercom_conv_id" "redacted"; exit 0
fi
if ! jq -e . "$body_file" >/dev/null 2>&1; then
  _emit_error "invalid_body" "body-file is not valid JSON"; exit 0
fi

customer_email_lc="$(printf %s "$customer_email" | tr '[:upper:]' '[:lower:]')"
body_hash="$(jq -S -c . "$body_file" | _sha256)"

# Defense-in-depth: OPS_DRY_RUN=1 would short-circuit the PUT into a synthetic 200.
if [[ "${OPS_DRY_RUN:-0}" == "1" ]]; then
  _emit_error "ops_dry_run_set" "OPS_DRY_RUN=1 is set in env; refusing — would short-circuit the PUT into a synthetic 200"
  exit 0
fi

if ! _audit_probe; then
  _emit_error "audit_unwritable" "cannot write to $AUDIT_LOG; refusing"
  exit 0
fi

# --apply requires --intercom-conv-id (so we can re-fetch the trusted email).
if (( apply == 1 )) && [[ -z "$intercom_conv_id" ]]; then
  _audit "refused_intercom_conv_id_required" "apply_without_conv_id"
  _emit_error "intercom_conv_id_required" "--apply requires --intercom-conv-id"
  exit 0
fi

# --- Body required-field / length sanity (authoritative check is the TS dispatcher) ---
b_name="$(jq -r '.name // ""' "$body_file")"
b_phone="$(jq -r '.phoneNumber // ""' "$body_file")"
b_line1="$(jq -r '.address.line1 // ""' "$body_file")"
b_city="$(jq -r '.address.city // ""' "$body_file")"
b_postcode="$(jq -r '.address.postal_code // ""' "$body_file")"
b_country="$(jq -r '.address.country // ""' "$body_file")"

for pair in "name:$b_name" "phone:$b_phone" "line1:$b_line1" "city:$b_city" "postcode:$b_postcode" "country:$b_country"; do
  if [[ -z "${pair#*:}" ]]; then
    _emit_error "address_incomplete" "missing required field: ${pair%%:*}"; exit 0
  fi
done
# country must be a 2-letter ISO code (backend maps it straight to Prodigi
# countryCode). Defense-in-depth — the TS validator is authoritative.
if ! [[ "$b_country" =~ ^[A-Za-z][A-Za-z]$ ]]; then
  _emit_error "invalid_country" "country must be a 2-letter ISO code (got: $b_country)"; exit 0
fi
# Each rendered line must be <= 40 chars (Prodigi hard limit).
while IFS= read -r _v; do
  if (( ${#_v} > PRODIGI_MAX_LINE )); then
    _emit_error "address_line_too_long" "a field exceeds ${PRODIGI_MAX_LINE} chars"; exit 0
  fi
done < <(jq -r '[.name, .phoneNumber, .address.line1, (.address.line2 // ""), .address.city, (.address.state // ""), .address.postal_code, .address.country] | .[]' "$body_file")

# --- Resolve the order (GET) — gives us the canonical UUID + owner email + status ---
if [[ -z "$MUSO_ADMIN_API" || ! -f "$MUSO_ADMIN_API" ]]; then
  _emit_error "missing_admin_api_script" "muso-admin-api.sh not found"; exit 0
fi

order_resp="$(bash "$MUSO_ADMIN_API" --requester "$customer_email" call GET "/admin/orders/$order_ref" 2>/dev/null || true)"
order_http="$(printf %s "$order_resp" | jq -r '.http_status // 0' 2>/dev/null || echo 0)"
if [[ "$order_http" != "200" ]]; then
  _audit "refused_order_lookup_failed" "http_$order_http"
  _emit_error "order_lookup_failed" "could not load order (status $order_http)"; exit 0
fi

order_id_uuid="$(printf %s "$order_resp" | jq -r '.body.data.id // empty' 2>/dev/null)"
order_status="$(printf %s "$order_resp" | jq -r '.body.data.status // empty' 2>/dev/null)"
owner_email_lc="$(printf %s "$order_resp" | jq -r '.body.data.customerEmail // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')"
current_address="$(printf %s "$order_resp" | jq -c '.body.data.shipment.address // null' 2>/dev/null || echo null)"

if [[ -z "$order_id_uuid" ]]; then
  _audit "refused_order_unresolved" "no_id_in_response"
  _emit_error "order_lookup_failed" "order resolved but carried no id"; exit 0
fi

# --- Ownership gate (fail-closed) ---
# (a) the order's owner email must match the requester.
if [[ -z "$owner_email_lc" ]]; then
  _audit "refused_owner_undetermined" "no_customer_email_on_order"
  _emit_error "owner_undetermined" "could not confirm who owns this order"; exit 0
fi
if [[ "$owner_email_lc" != "$customer_email_lc" ]]; then
  _audit "refused_owner_mismatch" "requester_not_owner"
  _emit_error "owner_mismatch" "the requester is not the owner of this order"; exit 0
fi
# (b) re-verify the requester email against Intercom's contact record (when a
# conv-id is present — always on apply). Closes the typed-email injection vector.
if [[ -n "$intercom_conv_id" ]]; then
  if ! _verify_intercom_email "$intercom_conv_id" "$customer_email_lc"; then
    _audit "refused_intercom_email_mismatch" "intercom_contact_mismatch"
    _emit_error "intercom_email_mismatch" "could not confirm this is the order owner"; exit 0
  fi
fi

# --- Dry-run: preview only, record a would_update row ---
if (( apply == 0 )); then
  _audit "would_update" "" "$order_http"
  jq -n -c \
    --arg order_ref "$order_ref" \
    --arg order_id "$order_id_uuid" \
    --arg status "$order_status" \
    --argjson current_address "$current_address" \
    --slurpfile body "$body_file" \
    '{
      ok: true, mode: "dry-run", applied: false,
      order_ref: $order_ref, order_id: $order_id, order_status: $status,
      current_address: $current_address,
      proposed: $body[0],
      editable: ($status == "PAID" or $status == "PROCESSING")
    }'
  exit 0
fi

# --- Apply path ---
# Mechanical dry-run-before-apply gate.
if ! _recent_dry_run_exists; then
  _audit "refused_dry_run_required" "no_recent_would_update"
  _emit_error "dry_run_required" "run a dry-run preview and confirm within 15 minutes before applying"; exit 0
fi

# Per-day cap (apply only).
today="$(date -u +%Y-%m-%d)"
today_count=0
if [[ -f "$AUDIT_LOG" ]]; then
  today_count="$(jq -r --arg d "$today" --arg email "$customer_email_lc" \
    'select(.status == "updated" and (.ts | startswith($d)) and .requester_email == $email) | 1' \
    "$AUDIT_LOG" 2>/dev/null | wc -l | tr -d ' ')"
fi
if (( today_count >= MAX_PER_CUSTOMER_PER_DAY )); then
  _audit "refused_cap_exceeded_per_day" "count_$today_count"
  _emit_error "cap_exceeded_per_day" "daily edit cap reached; flag for the team"; exit 0
fi

# PUT to the canonical UUID (the handler's findByPk needs the id, not orderNumber/Prodigi id).
put_body="$(jq -c . "$body_file")"
put_resp="$(bash "$MUSO_ADMIN_API" --requester "$customer_email" call PUT "/admin/orders/$order_id_uuid" "$put_body" 2>/dev/null || true)"
put_http="$(printf %s "$put_resp" | jq -r '.http_status // 0' 2>/dev/null || echo 0)"

if [[ "$put_http" == "200" ]]; then
  _audit "updated" "" "$put_http"
  jq -n -c \
    --arg order_ref "$order_ref" \
    --arg order_id "$order_id_uuid" \
    --slurpfile body "$body_file" \
    '{ok: true, mode: "apply", applied: true, order_ref: $order_ref, order_id: $order_id, http_status: 200, applied_recipient: $body[0]}'
  exit 0
fi

# Non-200: surface Prodigi/backend rejection (e.g. status not PAID/PROCESSING, or
# Prodigi outcome != Updated → backend 400). Caroline routes these to ops.
put_detail="$(printf %s "$put_resp" | jq -r '.body.message // .body.error // .body // empty' 2>/dev/null | head -c 300 || true)"
_audit "apply_failed" "http_$put_http" "$put_http"
jq -n -c \
  --arg order_ref "$order_ref" \
  --arg detail "$put_detail" \
  --arg http "$put_http" \
  '{ok: false, error: "apply_failed", order_ref: $order_ref, http_status: ($http | tonumber? // 0), detail: (if $detail=="" then null else $detail end)}'
exit 0
