#!/usr/bin/env bats
# muso-ad-screening.sh — one-route, one-method write wrapper (MUS-3642).
# Every refusal test asserts the muso stub was never invoked.

setup() {
  WRAPPER="$BATS_TEST_DIRNAME/../../skills-all/muso-ad-screening/scripts/muso-ad-screening.sh"
  export MUSO_BIN="$BATS_TEST_DIRNAME/fixtures/ad-screening/fake-muso.sh"
  export FAKE_MUSO_CALL_MARKER="$BATS_TEST_TMPDIR/calls"
  export AD_SCREENING_DISABLED_FILE="$BATS_TEST_TMPDIR/absent.disabled"
  export MUSO_ENV=prod
  unset MUSO_AD_SCREENING_ENV
  PAYLOAD="$BATS_TEST_TMPDIR/payload.json"
  echo '{"screeningKey":"k1","recommendation":"approve","confidence":0.9,"brandFit":"good","harmFlags":[],"reason":"ok","creativeDescription":"d","modelVersion":"v1"}' > "$PAYLOAD"
}

assert_stub_not_called() { [ ! -e "$FAKE_MUSO_CALL_MARKER" ]; }

@test "happy path: PUT to the built route with --requester" {
  run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$FAKE_MUSO_CALL_MARKER")" -eq 1 ]
  grep -qx -- "api PUT /admin/ads/4242/screening --data @$PAYLOAD --requester screener@hydra-ad-screening --env prod" "$FAKE_MUSO_CALL_MARKER"
  # --file is multipart upload in muso api, not a JSON body
  ! grep -q -- "--file" "$FAKE_MUSO_CALL_MARKER"
}

@test "muso's own exit code passes through on a permitted call" {
  FAKE_MUSO_RC=7 run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 7 ]
}

@test "non-numeric adId path traversal -> exit 3, stub not called" {
  run "$WRAPPER" put '4242/../../admin/user/1' "$PAYLOAD"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "non-numeric adId 'abc' -> exit 3, stub not called" {
  run "$WRAPPER" put abc "$PAYLOAD"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "empty adId -> exit 3, stub not called" {
  run "$WRAPPER" put '' "$PAYLOAD"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "adId with trailing newline -> exit 3, stub not called" {
  run "$WRAPPER" put $'4242\nfoo' "$PAYLOAD"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "extra top-level payload key -> exit 3, stub not called" {
  echo '{"screeningKey":"k1","isAdmin":true}' > "$PAYLOAD"
  run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "malformed JSON payload -> exit 3, stub not called" {
  echo '{not json' > "$PAYLOAD"
  run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "non-object JSON payload -> exit 3, stub not called" {
  echo '["screeningKey"]' > "$PAYLOAD"
  run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "missing payload file -> exit 3, stub not called" {
  run "$WRAPPER" put 4242 "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "any verb other than put -> exit 3, stub not called" {
  run "$WRAPPER" delete 4242 "$PAYLOAD"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "wrong arg count -> exit 2, stub not called" {
  run "$WRAPPER" put 4242
  [ "$status" -eq 2 ]
  assert_stub_not_called
}

@test "kill switch present -> exit 6, stub not called" {
  touch "$AD_SCREENING_DISABLED_FILE"
  run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 6 ]
  assert_stub_not_called
}

@test "AD_SCREENING_CALLER override sets the requester" {
  AD_SCREENING_CALLER=jev-screener run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 0 ]
  grep -q -- "--requester jev-screener@hydra-ad-screening" "$FAKE_MUSO_CALL_MARKER"
}

@test "AD_SCREENING_CALLER with unsafe chars -> exit 3, stub not called" {
  AD_SCREENING_CALLER='a b' run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "MUSO_ENV unset and no override -> exit 3 refused, stub not called" {
  unset MUSO_ENV
  run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 3 ]
  [[ "$output" == *"refused — MUSO_ENV unset"* ]]
  assert_stub_not_called
}

@test "MUSO_ENV empty and no override -> exit 3 refused, stub not called" {
  MUSO_ENV= run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 3 ]
  assert_stub_not_called
}

@test "MUSO_ENV=dev passes --env dev explicitly" {
  MUSO_ENV=dev run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 0 ]
  grep -q -- " --env dev$" "$FAKE_MUSO_CALL_MARKER"
}

@test "MUSO_AD_SCREENING_ENV wins over MUSO_ENV" {
  MUSO_ENV=prod MUSO_AD_SCREENING_ENV=dev run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 0 ]
  grep -q -- " --env dev$" "$FAKE_MUSO_CALL_MARKER"
  ! grep -q -- "--env prod" "$FAKE_MUSO_CALL_MARKER"
}

@test "MUSO_AD_SCREENING_ENV alone is enough when MUSO_ENV is unset" {
  unset MUSO_ENV
  MUSO_AD_SCREENING_ENV=prod run "$WRAPPER" put 4242 "$PAYLOAD"
  [ "$status" -eq 0 ]
  grep -q -- " --env prod$" "$FAKE_MUSO_CALL_MARKER"
}
