#!/usr/bin/env bats

# Tests for remove-credits.sh – the destructive bash mutation surface for
# Caroline self-service credit removal.
#
# Stubs (via PATH-shadow):
#   - muso-admin-api.sh   – emits canned response from $MUSO_API_RESPONSE_FILE
#                           (one envelope per request, in order; cycles to
#                           last on overflow).
#   - curl                – emits $CURL_STUB_RESPONSE for Intercom verify.
#
# NEVER hits real APIs / real Slack. Follows the discipline codified by
# feedback_bats_must_stub_openclaw.md.

setup() {
  TEST_TMP="$(mktemp -d -t ccr-bats.XXXXXX)"
  AUDIT_LOG="$TEST_TMP/audit.jsonl"
  STUB_DIR="$TEST_TMP/bin"
  mkdir -p "$STUB_DIR"
  TRACKS_FILE="$TEST_TMP/tracks.txt"
  echo "Some Artist - Some Track" > "$TRACKS_FILE"

  # Stub muso-admin-api.sh – reads sequential responses from a file.
  cat > "$STUB_DIR/muso-admin-api.sh" <<'STUBEOF'
#!/usr/bin/env bash
# Called as: muso-admin-api.sh call <METHOD> <PATH>
# Reads canned envelopes line-by-line from $MUSO_API_RESPONSE_FILE (one per
# call). State carried via $MUSO_API_CURSOR_FILE (a counter).
RESP="${MUSO_API_RESPONSE_FILE:-}"
CURSOR="${MUSO_API_CURSOR_FILE:-/dev/null}"
if [[ -z "$RESP" ]] || [[ ! -f "$RESP" ]]; then
  echo '{"http_status":500,"body":{"error":"stub_not_configured"}}'
  exit 0
fi
n=0
if [[ -f "$CURSOR" ]]; then n="$(cat "$CURSOR" 2>/dev/null || echo 0)"; fi
n=$(( n + 1 ))
echo "$n" > "$CURSOR"
# Get nth line; if past end, repeat last
total="$(wc -l < "$RESP" | tr -d ' ')"
if (( n > total )); then n="$total"; fi
sed -n "${n}p" "$RESP"
STUBEOF
  chmod +x "$STUB_DIR/muso-admin-api.sh"

  # Stub curl – only Intercom verify uses curl; others go through muso-admin-api.sh
  cat > "$STUB_DIR/curl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ -n "${CURL_STUB_RESPONSE:-}" ]]; then
  echo "$CURL_STUB_RESPONSE"
fi
STUBEOF
  chmod +x "$STUB_DIR/curl"

  export PATH="$STUB_DIR:$PATH"
  export MUSO_ADMIN_API_SCRIPT="$STUB_DIR/muso-admin-api.sh"
  export MUSO_API_RESPONSE_FILE="$TEST_TMP/api-responses.jsonl"
  export MUSO_API_CURSOR_FILE="$TEST_TMP/api-cursor"
  export CCR_AUDIT_LOG="$AUDIT_LOG"
  export CCR_INTERCOM_API_BASE="http://stub.invalid"
  export MUSOAI_INTERCOM_TOKEN="test-token-bats"
  # Intercom verify stub: match emails by default (override per-test).
  export CURL_STUB_RESPONSE='{"source":{"author":{"email":"owner@example.com"}}}'

  # Repo paths
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SCRIPT="$REPO_ROOT/workspaces/support/skills/customer-credit-removal/scripts/remove-credits.sh"

  # Fixture profile UUID + email used across most tests
  PROFILE_ID="aa9f3eb3-77ba-46f3-b6cd-db0898e5caf8"
  REQUESTER_EMAIL="owner@example.com"
  CONV_ID="12345"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Convenience: queue one or more API responses in order.
api_responses() {
  : > "$MUSO_API_RESPONSE_FILE"
  for r in "$@"; do
    printf '%s\n' "$r" >> "$MUSO_API_RESPONSE_FILE"
  done
}

# Convenience: extract a JSON field from $output
jget() { printf '%s' "$output" | jq -r "$1"; }

# Standard "profile is claimed, single workspace, matching email" envelope.
ok_profile_envelope() {
  cat <<JSON
{"http_status":200,"body":{"data":{"isClaimed":true,"name":"Owner Name","workspaces":[{"isClaimed":true,"email":"$REQUESTER_EMAIL"}]}}}
JSON
}

# Credits page with one matching track. Uses `totalCount` (the live admin
# API field) rather than `total` – the wrapper's pagination loop reads
# `.totalCount // .total // 0` for forward-compat.
one_credit_envelope() {
  local track_id="$1"
  cat <<JSON
{"http_status":200,"body":{"data":{"totalCount":1,"items":[{"id":"$track_id","title":"Some Track","artists":[{"name":"Some Artist"}],"credits":["Featured Artist"]}]}}}
JSON
}

# Credits page with one matching track where owner has a production role.
producer_credit_envelope() {
  local track_id="$1"
  cat <<JSON
{"http_status":200,"body":{"data":{"totalCount":1,"items":[{"id":"$track_id","title":"Some Track","artists":[{"name":"Other Artist"}],"credits":["Producer"]}]}}}
JSON
}

# --- A. Argv refusals (no API/curl stub needed) ---

@test "syntax-checks via bash -n" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "--help exits 0 with help text" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "remove-credits.sh"
  echo "$output" | grep -qi -- "--intercom-conv-id"
}

@test "missing --profile-id" {
  run bash "$SCRIPT" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "missing --requester-email" {
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "missing --tracks-file" {
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --requester-email "$REQUESTER_EMAIL"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "missing_arg" ]
}

@test "tracks_file_missing on nonexistent path" {
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TEST_TMP/nope.txt"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "tracks_file_missing" ]
}

@test "invalid_profile_id rejects non-UUID" {
  run bash "$SCRIPT" --profile-id "not-a-uuid" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_profile_id" ]
}

@test "invalid_requester_email rejects malformed email" {
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --requester-email "not-an-email" --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_requester_email" ]
}

@test "invalid_intercom_conv_id rejects URL-control characters" {
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "abc/../escape"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "invalid_intercom_conv_id" ]
}

@test "unknown_arg refused" {
  run bash "$SCRIPT" --bogus-flag value --profile-id "$PROFILE_ID" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "unknown_arg" ]
}

@test "intercom_conv_id_required when --apply without --intercom-conv-id" {
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --apply
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "intercom_conv_id_required" ]
}

@test "empty_tracks_file when file has no non-blank lines" {
  echo -n "" > "$TEST_TMP/empty.txt"
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TEST_TMP/empty.txt"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "empty_tracks_file" ]
}

@test "cap_exceeded_per_request when >50 tracks" {
  : > "$TEST_TMP/big.txt"
  for i in $(seq 1 51); do echo "Artist $i - Track $i" >> "$TEST_TMP/big.txt"; done
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TEST_TMP/big.txt"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "cap_exceeded_per_request" ]
}

# --- B. Env-based refusals (no stub responses needed) ---

@test "ops_dry_run_set when OPS_DRY_RUN=1 in env" {
  run env OPS_DRY_RUN=1 bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "ops_dry_run_set" ]
}

@test "audit_unwritable when audit dir is not writable" {
  # Use a path where mkdir -p deterministically fails because a regular
  # file blocks the parent – works under root (chmod 555 wouldn't, since
  # root bypasses DAC perms). The blocker file makes
  # `mkdir -p $TEST_TMP/blocker/nested` fail with ENOTDIR for every user.
  : > "$TEST_TMP/blocker"
  run env CCR_AUDIT_LOG="$TEST_TMP/blocker/nested/audit.jsonl" bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "audit_unwritable" ]
}

# --- C. Ownership refusals (need muso-admin-api stub) ---

@test "profile_unclaimed when isClaimed=false" {
  api_responses '{"http_status":200,"body":{"data":{"isClaimed":false,"workspaces":[]}}}'
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "profile_unclaimed" ]
}

@test "no_claimed_workspace when isClaimed=true but workspaces[] empty/all-unclaimed" {
  api_responses '{"http_status":200,"body":{"data":{"isClaimed":true,"workspaces":[{"isClaimed":false,"email":"foo@bar.com"}]}}}'
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "no_claimed_workspace" ]
}

@test "profile_multi_claimed when 2+ workspaces are claimed" {
  api_responses '{"http_status":200,"body":{"data":{"isClaimed":true,"workspaces":[{"isClaimed":true,"email":"a@x.com"},{"isClaimed":true,"email":"b@y.com"}]}}}'
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "profile_multi_claimed" ]
}

@test "owner_mismatch when claimed-workspace email differs" {
  api_responses '{"http_status":200,"body":{"data":{"isClaimed":true,"workspaces":[{"isClaimed":true,"email":"someone-else@example.com"}]}}}'
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "owner_mismatch" ]
}

@test "profile_lookup_failed on non-200 HTTP" {
  api_responses '{"http_status":500,"body":{"error":"oops"}}'
  run bash "$SCRIPT" --profile-id "$PROFILE_ID" --requester-email "$REQUESTER_EMAIL" --tracks-file "$TRACKS_FILE"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "profile_lookup_failed" ]
}

# --- D. Intercom verification ---

@test "intercom_email_mismatch refuses when Intercom author.email differs" {
  api_responses "$(ok_profile_envelope)" "$(one_credit_envelope deadbeef-dead-dead-dead-deadbeefcafe)"
  export CURL_STUB_RESPONSE='{"source":{"author":{"email":"impostor@elsewhere.com"}}}'
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "$CONV_ID"
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "intercom_email_mismatch" ]
}

# --- E. Dry-run resolution paths ---

@test "dry-run: would_remove written when track matches" {
  api_responses "$(ok_profile_envelope)" "$(one_credit_envelope deadbeef-dead-dead-dead-deadbeefcafe)"
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "$CONV_ID"
  [ "$status" -eq 0 ]
  [ "$(jget '.ok')" = "true" ]
  [ "$(jget '.mode')" = "dry-run" ]
  [ "$(jget '.results[0].status')" = "would_remove" ]
  # Audit row written
  grep -q '"status":"would_remove"' "$AUDIT_LOG"
  grep -q '"track_id":"deadbeef-dead-dead-dead-deadbeefcafe"' "$AUDIT_LOG"
}

@test "dry-run: not_found when title doesn't match any credit" {
  api_responses "$(ok_profile_envelope)" '{"http_status":200,"body":{"data":{"total":1,"items":[{"id":"deadbeef-dead-dead-dead-deadbeefcafe","title":"Different Track","artists":[{"name":"Different Artist"}],"credits":["Featured Artist"]}]}}}'
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "$CONV_ID"
  [ "$status" -eq 0 ]
  [ "$(jget '.results[0].status')" = "not_found" ]
}

@test "dry-run: refused_production_role_on_track when owner has Producer credit" {
  # Alexxx pattern (ticket 869ck6tv6): owner is the Producer on a track
  # primarily by Other Artist. Customer correctly names "Other Artist - Track"
  # because that's how the track is listed; the matcher resolves the credit,
  # and the producer-role guard kicks in to refuse mechanical removal.
  echo "Other Artist - Some Track" > "$TRACKS_FILE"
  api_responses "$(ok_profile_envelope)" "$(producer_credit_envelope deadbeef-dead-dead-dead-deadbeefcafe)"
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "$CONV_ID"
  [ "$status" -eq 0 ]
  [ "$(jget '.results[0].status')" = "refused_production_role_on_track" ]
  [ "$(jget '.summary.refused_production_role_on_track')" = "1" ]
  # Audit row for the refusal exists
  grep -q '"status":"refused_production_role_on_track"' "$AUDIT_LOG"
}

# --- F. Apply gate ---

@test "apply: dry_run_required when no prior would_remove exists" {
  # Ownership + Intercom + credits-list responses, then DELETE (won't be reached)
  api_responses "$(ok_profile_envelope)" "$(one_credit_envelope deadbeef-dead-dead-dead-deadbeefcafe)"
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "$CONV_ID" \
    --apply
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "dry_run_required" ]
  # No DELETE-side audit row written
  ! grep -q '"status":"removed"' "$AUDIT_LOG"
}

@test "apply: dry_run_required when prior would_remove is stale" {
  # Seed a stale (10 hours ago) would_remove row directly into the audit log.
  stale_ts="$(date -u -v-10H +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '10 hours ago' +'%Y-%m-%dT%H:%M:%SZ')"
  cat > "$AUDIT_LOG" <<EOF
{"ts":"$stale_ts","profile_id":"$PROFILE_ID","requester_email":"$REQUESTER_EMAIL","intercom_conv_id":"$CONV_ID","mode":"dry-run","status":"would_remove","track_id":"deadbeef-dead-dead-dead-deadbeefcafe","title":"Some Track","reason":null,"http_status":null}
EOF
  api_responses "$(ok_profile_envelope)" "$(one_credit_envelope deadbeef-dead-dead-dead-deadbeefcafe)"
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "$CONV_ID" \
    --apply
  [ "$status" -eq 0 ]
  [ "$(jget .error)" = "dry_run_required" ]
}

@test "apply: happy path issues DELETE when recent dry-run exists" {
  # Seed a fresh would_remove row
  fresh_ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  cat > "$AUDIT_LOG" <<EOF
{"ts":"$fresh_ts","profile_id":"$PROFILE_ID","requester_email":"$REQUESTER_EMAIL","intercom_conv_id":"$CONV_ID","mode":"dry-run","status":"would_remove","track_id":"deadbeef-dead-dead-dead-deadbeefcafe","title":"Some Track","reason":null,"http_status":null}
EOF
  # Responses: profile, credits page, DELETE
  api_responses \
    "$(ok_profile_envelope)" \
    "$(one_credit_envelope deadbeef-dead-dead-dead-deadbeefcafe)" \
    '{"http_status":200,"body":{"ok":true}}'
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "$CONV_ID" \
    --apply
  [ "$status" -eq 0 ]
  [ "$(jget '.ok')" = "true" ]
  [ "$(jget '.mode')" = "apply" ]
  [ "$(jget '.summary.removed')" = "1" ]
  [ "$(jget '.results[0].status')" = "removed" ]
  [ "$(jget '.results[0].http_status')" = "200" ]
  # Audit row for the apply-side removal must exist with the load-bearing keys
  grep -q '"status":"removed"' "$AUDIT_LOG"
  grep -q '"http_status":200' "$AUDIT_LOG"
  grep -q '"mode":"apply"' "$AUDIT_LOG"
}

@test "apply: 400 from artist-role removal surfaces upstream body in result" {
  fresh_ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  cat > "$AUDIT_LOG" <<EOF
{"ts":"$fresh_ts","profile_id":"$PROFILE_ID","requester_email":"$REQUESTER_EMAIL","intercom_conv_id":"$CONV_ID","mode":"dry-run","status":"would_remove","track_id":"deadbeef-dead-dead-dead-deadbeefcafe","title":"Some Track","reason":null,"http_status":null}
EOF
  # Backend rejects artist-role removal unless ?force=true. The wrapper
  # must surface that body text so the action-request handler can route
  # on it rather than reporting a generic "errors" with no context.
  api_responses \
    "$(ok_profile_envelope)" \
    "$(one_credit_envelope deadbeef-dead-dead-dead-deadbeefcafe)" \
    '{"http_status":400,"body":{"error":"force=true required to remove artist role on track"}}'
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "$CONV_ID" \
    --apply
  [ "$status" -eq 0 ]
  [ "$(jget '.summary.errors')" = "1" ]
  [ "$(jget '.results[0].status')" = "error" ]
  [ "$(jget '.results[0].http_status')" = "400" ]
  # upstream_body should contain the error reason
  printf '%s' "$output" | grep -q "force=true"
}

@test "pagination: falls back to .total when .totalCount missing (back-compat)" {
  # Legacy/draft API responses may still use the old `total` field name.
  # The wrapper reads `.totalCount // .total // 0` to handle both.
  api_responses "$(ok_profile_envelope)" \
    '{"http_status":200,"body":{"data":{"total":1,"items":[{"id":"deadbeef-dead-dead-dead-deadbeefcafe","title":"Some Track","artists":[{"name":"Some Artist"}],"credits":["Featured Artist"]}]}}}'
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "$CONV_ID"
  [ "$status" -eq 0 ]
  [ "$(jget '.results[0].status')" = "would_remove" ]
}

@test "apply: OPS_DRY_RUN trapdoor – dryRun:true response treated as error, not removed" {
  fresh_ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  cat > "$AUDIT_LOG" <<EOF
{"ts":"$fresh_ts","profile_id":"$PROFILE_ID","requester_email":"$REQUESTER_EMAIL","intercom_conv_id":"$CONV_ID","mode":"dry-run","status":"would_remove","track_id":"deadbeef-dead-dead-dead-deadbeefcafe","title":"Some Track","reason":null,"http_status":null}
EOF
  # Note: we don't set OPS_DRY_RUN=1 (that's caught earlier). This simulates
  # the upstream script short-circuiting independently and returning a
  # synthetic dryRun envelope to the DELETE call.
  api_responses \
    "$(ok_profile_envelope)" \
    "$(one_credit_envelope deadbeef-dead-dead-dead-deadbeefcafe)" \
    '{"http_status":200,"dryRun":true,"body":null,"wouldHaveExecuted":true}'
  run bash "$SCRIPT" \
    --profile-id "$PROFILE_ID" \
    --requester-email "$REQUESTER_EMAIL" \
    --tracks-file "$TRACKS_FILE" \
    --intercom-conv-id "$CONV_ID" \
    --apply
  [ "$status" -eq 0 ]
  [ "$(jget '.summary.removed')" = "0" ]
  [ "$(jget '.summary.errors')" = "1" ]
  [ "$(jget '.results[0].status')" = "error" ]
  [ "$(jget '.results[0].reason')" = "upstream_dry_run_short_circuit" ]
  # Audit row reflects refusal, not "removed"
  ! grep -q '"status":"removed"' "$AUDIT_LOG"
  grep -q '"reason":"upstream_dry_run_short_circuit"' "$AUDIT_LOG"
}
