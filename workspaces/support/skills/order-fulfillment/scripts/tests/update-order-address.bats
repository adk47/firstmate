#!/usr/bin/env bats

# Tests for update-order-address.sh — the destructive bash mutation surface +
# ownership/audit security boundary for Caroline's order shipping-address edits.
#
# Stubs (via PATH-shadow + env), NEVER hits real APIs (mirrors remove-credits.bats):
#   - muso-admin-api.sh — emits canned envelopes from $MUSO_API_RESPONSE_FILE,
#                         one per call, in order (GET order, then PUT), via a cursor.
#   - curl              — emits $CURL_STUB_RESPONSE (Intercom contact verify).

setup() {
  TEST_TMP="$(mktemp -d -t oua-bats.XXXXXX)"
  STUB_DIR="$TEST_TMP/bin"
  mkdir -p "$STUB_DIR"

  cat > "$STUB_DIR/muso-admin-api.sh" <<'STUBEOF'
#!/usr/bin/env bash
RESP="${MUSO_API_RESPONSE_FILE:-}"
CURSOR="${MUSO_API_CURSOR_FILE:-/dev/null}"
if [[ -z "$RESP" ]] || [[ ! -f "$RESP" ]]; then
  echo '{"http_status":500,"body":{"error":"stub_not_configured"}}'; exit 0
fi
n=0; [[ -f "$CURSOR" ]] && n="$(cat "$CURSOR" 2>/dev/null || echo 0)"
n=$(( n + 1 )); echo "$n" > "$CURSOR"
total="$(wc -l < "$RESP" | tr -d ' ')"; (( n > total )) && n="$total"
sed -n "${n}p" "$RESP"
STUBEOF
  chmod +x "$STUB_DIR/muso-admin-api.sh"

  cat > "$STUB_DIR/curl" <<'STUBEOF'
#!/usr/bin/env bash
[[ -n "${CURL_STUB_RESPONSE:-}" ]] && echo "$CURL_STUB_RESPONSE"
STUBEOF
  chmod +x "$STUB_DIR/curl"

  export PATH="$STUB_DIR:$PATH"
  export MUSO_ADMIN_API_SCRIPT="$STUB_DIR/muso-admin-api.sh"
  export MUSO_API_RESPONSE_FILE="$TEST_TMP/api-responses.jsonl"
  export MUSO_API_CURSOR_FILE="$TEST_TMP/api-cursor"
  export OUA_AUDIT_LOG="$TEST_TMP/audit.jsonl"
  export OUA_INTERCOM_API_BASE="http://stub.invalid"
  export MUSOAI_INTERCOM_TOKEN="test-token-bats"
  # Intercom verify stub: matches the owner by default (override per-test).
  export CURL_STUB_RESPONSE='{"source":{"author":{"email":"owner@example.com"}}}'

  SCRIPT="$BATS_TEST_DIRNAME/../update-order-address.sh"
  ORDER_REF="6a468d83-b71d-4720-bb12-79ae8dfa55f8"
  REQUESTER_EMAIL="owner@example.com"
  CONV_ID="12345"

  BODY_FILE="$TEST_TMP/body.json"
  printf '%s' '{"name":"Maria Perez","phoneNumber":"+18095550100","address":{"line1":"Av Enriquillo 36","line2":"Apt 1101","city":"Santo Domingo","postal_code":"11108","country":"DO"}}' > "$BODY_FILE"
}

teardown() { rm -rf "$TEST_TMP"; }

api_responses() { : > "$MUSO_API_RESPONSE_FILE"; for r in "$@"; do printf '%s\n' "$r" >> "$MUSO_API_RESPONSE_FILE"; done; }
jget() { printf '%s' "$output" | jq -r "$1"; }

# Order GET envelope: status PROCESSING, owner = $1, address on file.
order_envelope() {
  local owner="${1:-$REQUESTER_EMAIL}"
  printf '{"http_status":200,"body":{"data":{"id":"%s","status":"PROCESSING","customerEmail":"%s","shipment":{"address":{"line1":"apto 1101"}}}}}' "$ORDER_REF" "$owner"
}

run_dry() { run bash "$SCRIPT" --order-ref "$ORDER_REF" --customer-email "$REQUESTER_EMAIL" --body-file "$BODY_FILE" --intercom-conv-id "$CONV_ID"; }
run_apply() { run bash "$SCRIPT" --order-ref "$ORDER_REF" --customer-email "$REQUESTER_EMAIL" --body-file "$BODY_FILE" --intercom-conv-id "$CONV_ID" --apply; }

@test "dry-run with matching owner returns a preview and writes a would_update row (no PUT)" {
  api_responses "$(order_envelope)"
  run_dry
  [ "$status" -eq 0 ]
  [ "$(jget '.ok')" = "true" ]
  [ "$(jget '.mode')" = "dry-run" ]
  [ "$(jget '.applied')" = "false" ]
  grep -q '"status":"would_update"' "$OUA_AUDIT_LOG"
}

@test "refuses when the requester is not the order owner" {
  api_responses "$(order_envelope "someone.else@example.com")"
  run_dry
  [ "$(jget '.error')" = "owner_mismatch" ]
}

@test "refuses on Intercom contact email mismatch (anti-spoof)" {
  api_responses "$(order_envelope)"
  CURL_STUB_RESPONSE='{"source":{"author":{"email":"impostor@example.com"}}}' run_dry
  [ "$(jget '.error')" = "intercom_email_mismatch" ]
}

@test "refuses an order that fails to resolve (GET non-200)" {
  api_responses '{"http_status":404,"body":{"error":"not found"}}'
  run_dry
  [ "$(jget '.error')" = "order_lookup_failed" ]
}

@test "apply without a recent dry-run is refused" {
  api_responses "$(order_envelope)"
  run_apply
  [ "$(jget '.error')" = "dry_run_required" ]
}

@test "apply succeeds after a dry-run with the same body" {
  api_responses "$(order_envelope)" "$(order_envelope)" '{"http_status":200,"body":{"result":"ok"}}'
  run_dry
  [ "$(jget '.mode')" = "dry-run" ]
  run_apply
  [ "$(jget '.ok')" = "true" ]
  [ "$(jget '.applied')" = "true" ]
  grep -q '"status":"updated"' "$OUA_AUDIT_LOG"
}

@test "a non-200 PUT surfaces apply_failed as valid JSON, even when http_status is non-numeric" {
  api_responses "$(order_envelope)" "$(order_envelope)" '{"http_status":"unknown","body":{"message":"prodigi rejected"}}'
  run_dry
  run_apply
  [ "$(jget '.error')" = "apply_failed" ]
  [ "$(jget '.http_status')" = "0" ]
}

@test "per-day cap blocks further applies" {
  local hash today
  hash="$(jq -S -c . "$BODY_FILE" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}')"
  today="$(date -u +%Y-%m-%d)"
  : > "$OUA_AUDIT_LOG"
  for _ in $(seq 1 10); do
    printf '{"ts":"%sT00:00:01Z","order_ref":"%s","requester_email":"%s","status":"updated"}\n' "$today" "$ORDER_REF" "$REQUESTER_EMAIL" >> "$OUA_AUDIT_LOG"
  done
  printf '{"ts":"%s","order_ref":"%s","requester_email":"%s","status":"would_update","body_hash":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ORDER_REF" "$REQUESTER_EMAIL" "$hash" >> "$OUA_AUDIT_LOG"
  api_responses "$(order_envelope)"
  run_apply
  [ "$(jget '.error')" = "cap_exceeded_per_day" ]
}

@test "missing a required field (no phone) is refused before any API call" {
  printf '%s' '{"name":"Maria Perez","address":{"line1":"x","city":"y","postal_code":"1","country":"DO"}}' > "$BODY_FILE"
  run_dry
  [ "$(jget '.error')" = "address_incomplete" ]
}

@test "a full country name (not ISO-2) is refused" {
  printf '%s' '{"name":"Maria Perez","phoneNumber":"+18095550100","address":{"line1":"x","city":"y","postal_code":"1","country":"Dominican Republic"}}' > "$BODY_FILE"
  run_dry
  [ "$(jget '.error')" = "invalid_country" ]
}

@test "OPS_DRY_RUN=1 in env refuses (no synthetic-200 short-circuit)" {
  api_responses "$(order_envelope)"
  OPS_DRY_RUN=1 run_dry
  [ "$(jget '.error')" = "ops_dry_run_set" ]
}

@test "--apply without --intercom-conv-id is refused" {
  api_responses "$(order_envelope)"
  run bash "$SCRIPT" --order-ref "$ORDER_REF" --customer-email "$REQUESTER_EMAIL" --body-file "$BODY_FILE" --apply
  [ "$(jget '.error')" = "intercom_conv_id_required" ]
}
