#!/usr/bin/env bats
# Tests for fastlane.sh — the deterministic "@Ops fastlane <profile>" wrapper.
#
# Contract under test:
# - "fastlane" means POST /admin/analytics/<uuid>/fast-lane (analytics bootstrap),
#   NEVER credit verification.
# - --lane plus fires POST /admin/analytics/<uuid>/fast-lane-plus; --scope user
#   fires POST /admin/user/<uuid>/fast-lane-plus (only valid with --lane plus).
#   No flags = plain (backward-compatible with the existing agent call).
# - Default triggerSource is lane/scope-aware (admin_fast_lane_jan_batch / _plus /
#   _plus_user) unless the caller passes arg 5.
# - fastlane+ surfaces discovered/refreshed; either false → warning, still exit 0.
# - UUIDs are extracted from bare ids AND credits.muso.ai/profile/<uuid> URLs,
#   lowercased, de-duped (one fire per unique profile).
# - real mode (default) sends {"triggerSource":...}; dry mode exports OPS_DRY_RUN=1.
# - A per-profile API failure is shown IN the report, and the wrapper still exits 0
#   (a trailing tool-error suppresses Slack delivery on this fleet).
# - Usage errors (no UUID / no requester / plain+user) exit 2.
# - Each fire writes a JSONL audit line (with lane/scope/endpoint).
#
# Hermetic: muso-admin-api.sh and trino-query.sh are PATH-independent stubs wired
# via FASTLANE_ADMIN_API / FASTLANE_TRINO. No network, no openclaw, no real API.

setup() {
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT
  SCRIPT="${BATS_TEST_DIRNAME}/../fastlane.sh"
  [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }

  export FASTLANE_AUDIT_PATH="$TEST_ROOT/fastlane-apply.jsonl"
  CALLS="$TEST_ROOT/admin-calls.log"; export CALLS

  # --- admin-api stub --------------------------------------------------------
  # Records each invocation (path | body | OPS_DRY_RUN) and emits the same
  # envelope shape the real `call` produces. A uuid containing "dead" returns
  # HTTP 500; OPS_DRY_RUN=1 returns the dry envelope. fast-lane-plus responses
  # carry data.discovered/data.refreshed (a "fa11" uuid → refreshed:false to
  # simulate a failed queue send); the per-user endpoint returns a per-profile
  # union under data.results.
  ADMIN_STUB="$TEST_ROOT/admin-stub.sh"; export FASTLANE_ADMIN_API="$ADMIN_STUB"
  cat >"$ADMIN_STUB" <<'STUB'
#!/usr/bin/env bash
# args: --requester <r> call POST <path> <body>
path=""; body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    call) shift; method="$1"; shift; path="$1"; shift; body="${1:-}"; shift || true ;;
    *) shift ;;
  esac
done
printf '%s | %s | OPS_DRY_RUN=%s\n' "$path" "$body" "${OPS_DRY_RUN:-unset}" >> "$CALLS"
if [[ "${OPS_DRY_RUN:-0}" == "1" ]]; then
  printf '%s\n' '{"http_status":200,"dryRun":true,"body":null,"wouldHaveExecuted":true}'
  exit 0
fi
if [[ "$path" == *dead* ]]; then
  printf '%s\n' '{"http_status":500,"body":{"result":"error","message":"boom"}}'
  exit 0
fi
id="$(printf '%s' "$path" | sed -E 's#.*/(analytics|user)/([^/]+)/.*#\2#')"
# per-user fastlane+ → a per-profile union (array under body.data.results).
if [[ "$path" == */admin/user/*/fast-lane-plus ]]; then
  printf '{"http_status":200,"body":{"result":"ok","code":200,"data":{"results":[{"profileId":"p1","refreshed":true},{"profileId":"p2","refreshed":true}]}}}\n'
  exit 0
fi
# profile fastlane+ → data carries discovered/refreshed (+bootstrapped).
if [[ "$path" == *fast-lane-plus ]]; then
  if [[ "$path" == *fa11* ]]; then
    printf '{"http_status":200,"body":{"result":"ok","code":200,"data":{"profileId":"%s","bootstrapped":true,"discovered":true,"refreshed":false}}}\n' "$id"
  else
    printf '{"http_status":200,"body":{"result":"ok","code":200,"data":{"profileId":"%s","bootstrapped":true,"discovered":true,"refreshed":true}}}\n' "$id"
  fi
  exit 0
fi
# plain fast-lane. A uuid starting "0b0b0b0b" gets a 200 body WITHOUT
# data.bootstrapped (the live backend omits it on some responses).
if [[ "$path" == *0b0b0b0b* ]]; then
  printf '{"http_status":200,"body":{"result":"ok","code":200,"data":{"profileId":"%s"}}}\n' "$id"
  exit 0
fi
printf '{"http_status":200,"body":{"result":"ok","code":200,"data":{"profileId":"%s","bootstrapped":true}}}\n' "$id"
STUB
  chmod +x "$ADMIN_STUB"

  # --- trino stub: one quoted CSV row (no header), matching Trino CSV output --
  # 5 fields: profile_credits_count, tracks_count, ce_streams, ce_spotify_streams, ce_youtube_streams
  # Records a marker to TRINO_CALLS so tests can assert whether readback ran.
  TRINO_CALLS="$TEST_ROOT/trino-calls.log"; export TRINO_CALLS
  TRINO_STUB="$TEST_ROOT/trino-stub.sh"; export FASTLANE_TRINO="$TRINO_STUB"
  cat >"$TRINO_STUB" <<'STUB'
#!/usr/bin/env bash
echo called >> "$TRINO_CALLS"
echo '"45","42","1234567","1000000","234567"'
STUB
  chmod +x "$TRINO_STUB"
}

teardown() { rm -rf "$TEST_ROOT"; }

@test "extracts and de-dupes UUIDs from mixed bare + URL input (one fire per profile)" {
  run bash "$SCRIPT" \
    "https://credits.muso.ai/profile/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 11111111-2222-3333-4444-555555555555 AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" \
    "1780000000.1" "U038BM16T7W" real
  [ "$status" -eq 0 ]
  # 3 tokens but only 2 unique (case-insensitive) → 2 calls.
  run wc -l <"$CALLS"
  [ "${output// /}" -eq 2 ]
  grep -q "/admin/analytics/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/fast-lane" "$CALLS"
  grep -q "/admin/analytics/11111111-2222-3333-4444-555555555555/fast-lane" "$CALLS"
}

@test "hits the analytics fast-lane endpoint with a triggerSource body (NOT credit verification)" {
  run bash "$SCRIPT" "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" real "admin_fast_lane_jan_batch"
  [ "$status" -eq 0 ]
  grep -q "/admin/analytics/11111111-2222-3333-4444-555555555555/fast-lane" "$CALLS"
  grep -q '"triggerSource":"admin_fast_lane_jan_batch"' "$CALLS"
  # Must NOT mention credit-requests / credit verification at all.
  ! grep -qi "credit-requests" "$CALLS"
  [[ "$output" == *"profile analytics bootstrap"* ]]
  [[ "$output" == *"enqueued"* ]]
  [[ "$output" == *"bootstrapped=true"* ]]
  # The user-facing report must NOT carry the internal disambiguation noise.
  [[ "$output" != *"not credit verification"* ]]
}

@test "omits bootstrapped from the report when the backend response lacks it (no '?')" {
  run bash "$SCRIPT" "0b0b0b0b-0000-0000-0000-000000000000" "" "U038BM16T7W" real
  [ "$status" -eq 0 ]
  [[ "$output" == *"enqueued (HTTP 200)"* ]]
  [[ "$output" != *"bootstrapped="* ]]
  [[ "$output" != *"bootstrapped=?"* ]]
}

@test "report includes stream/track readback from the live cube" {
  run bash "$SCRIPT" "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" real
  [ "$status" -eq 0 ]
  [[ "$output" == *"streams=1234567"* ]]
  [[ "$output" == *"tracks=42"* ]]
}

@test "dry mode exports OPS_DRY_RUN=1 and reports a no-write run" {
  run bash "$SCRIPT" "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" dry
  [ "$status" -eq 0 ]
  grep -q "OPS_DRY_RUN=1" "$CALLS"
  [[ "$output" == *"dry-run"* ]]
}

@test "per-profile API failure is shown in the report but exit stays 0 (delivery not suppressed)" {
  run bash "$SCRIPT" "deadbeef-0000-0000-0000-000000000000" "" "U038BM16T7W" real
  [ "$status" -eq 0 ]
  [[ "$output" == *"not enqueued"* ]]
  [[ "$output" == *"boom"* ]]
}

@test "writes a JSONL audit line per fire with success flag and endpoint" {
  run bash "$SCRIPT" "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" real
  [ "$status" -eq 0 ]
  [ -f "$FASTLANE_AUDIT_PATH" ]
  run jq -r '.action + "|" + (.success|tostring) + "|" + .endpoint' "$FASTLANE_AUDIT_PATH"
  [[ "$output" == "fast_lane_multi_profile|true|POST /admin/analytics/11111111-2222-3333-4444-555555555555/fast-lane" ]]
}

@test "no UUID in input is a usage error (exit 2)" {
  run bash "$SCRIPT" "please fastlane the rollo profile" "" "U038BM16T7W" real
  [ "$status" -eq 2 ]
  [[ "$output" == *"no profile UUID"* ]]
}

@test "missing requester is a usage error (exit 2)" {
  run bash "$SCRIPT" "11111111-2222-3333-4444-555555555555" "" "" real
  [ "$status" -eq 2 ]
  [[ "$output" == *"requester"* ]]
}

@test "invalid mode is a usage error (exit 2)" {
  run bash "$SCRIPT" "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" bogus
  [ "$status" -eq 2 ]
}

# --- fastlane+ (plus lane) --------------------------------------------------

@test "backward-compat: no flags hits plain /fast-lane, never fast-lane-plus" {
  run bash "$SCRIPT" "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" real
  [ "$status" -eq 0 ]
  grep -q "/admin/analytics/11111111-2222-3333-4444-555555555555/fast-lane |" "$CALLS"
  ! grep -q "fast-lane-plus" "$CALLS"
  grep -q '"triggerSource":"admin_fast_lane_jan_batch"' "$CALLS"
}

@test "--lane plus hits fast-lane-plus with the admin_fast_lane_plus default trigger" {
  run bash "$SCRIPT" --lane plus "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" real
  [ "$status" -eq 0 ]
  grep -q "/admin/analytics/11111111-2222-3333-4444-555555555555/fast-lane-plus" "$CALLS"
  grep -q '"triggerSource":"admin_fast_lane_plus"' "$CALLS"
  [[ "$output" == *"Fastlane+"* ]]
  [[ "$output" == *"discovered=true"* ]]
  [[ "$output" == *"refreshed=true"* ]]
}

@test "--lane plus --scope user hits the per-user endpoint, _plus_user trigger, no Trino readback" {
  run bash "$SCRIPT" --lane plus --scope user "99999999-8888-7777-6666-555555555555" "" "U038BM16T7W" real
  [ "$status" -eq 0 ]
  grep -q "/admin/user/99999999-8888-7777-6666-555555555555/fast-lane-plus" "$CALLS"
  grep -q '"triggerSource":"admin_fast_lane_plus_user"' "$CALLS"
  [[ "$output" == *"profiles processed"* ]]
  # user scope must NOT do the profile cube readback
  [ ! -f "$TRINO_CALLS" ]
  [[ "$output" != *"streams="* ]]
}

@test "fastlane+ with refreshed=false surfaces a warning but still exits 0" {
  run bash "$SCRIPT" --lane plus "fa11fa11-0000-0000-0000-000000000000" "" "U038BM16T7W" real
  [ "$status" -eq 0 ]
  # The literal false must survive jq extraction and reach the per-profile detail
  # line — `refreshed=false, HTTP` and the `logged + Sentry` warning string are
  # both unique to that line, NOT present in the static footer boilerplate (which
  # also contains "refreshed=false" / "queue send failed" — matching that would be
  # a tautology that passes even when extraction silently drops the false).
  [[ "$output" == *"refreshed=false, HTTP"* ]]
  [[ "$output" == *"logged + Sentry"* ]]
}

@test "--scope user without --lane plus is a usage error (exit 2)" {
  run bash "$SCRIPT" --scope user "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" real
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires --lane plus"* ]]
}

@test "unknown flag is a usage error (exit 2)" {
  run bash "$SCRIPT" --bogus plus "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" real
  [ "$status" -eq 2 ]
}

@test "dry mode with --lane plus still exports OPS_DRY_RUN=1 and targets fast-lane-plus" {
  run bash "$SCRIPT" --lane plus "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" dry
  [ "$status" -eq 0 ]
  grep -q "fast-lane-plus | .* | OPS_DRY_RUN=1" "$CALLS"
  [[ "$output" == *"dry-run"* ]]
}

@test "audit line for a plus fire records lane=plus and the fast-lane-plus endpoint" {
  run bash "$SCRIPT" --lane plus "11111111-2222-3333-4444-555555555555" "" "U038BM16T7W" real
  [ "$status" -eq 0 ]
  run jq -r '.lane + "|" + .scope + "|" + .endpoint + "|" + (.refreshed|tostring)' "$FASTLANE_AUDIT_PATH"
  [[ "$output" == "plus|profile|POST /admin/analytics/11111111-2222-3333-4444-555555555555/fast-lane-plus|true" ]]
}
