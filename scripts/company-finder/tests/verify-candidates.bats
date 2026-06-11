#!/usr/bin/env bats
#
# verify-candidates.sh makes "the company is still active" a mechanical HTTP
# check instead of model recall (6 dead companies shipped 2026-06-10). These
# tests pin the classification table — especially that bot-walled sites are
# KEPT (blocked) rather than false-dropped, and that a total connect failure
# is treated as our network problem, not 100% dead companies.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SUT="$REPO_ROOT/scripts/company-finder/verify-candidates.sh"
  export CURL_BIN="$BATS_TEST_DIRNAME/stubs/curl.sh"
  export VERIFY_SLEEP=0
  export VERIFY_STUB_COUNTER_DIR="$BATS_TEST_TMPDIR"
}

@test "a 200 site is alive and stamped with verified_at" {
  export VERIFY_STUB_MAP="alive.example=200"
  run bash "$SUT" <<<'[{"name":"Alive Co","domain":"https://www.alive.example/","why":"fits"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.alive' <<<"$output")" = "1" ]
  [ "$(jq -r '.alive[0].verification' <<<"$output")" = "alive" ]
  [ "$(jq -r '.alive[0].verified_at' <<<"$output")" != "null" ]
  # extra candidate keys are preserved
  [ "$(jq -r '.alive[0].why' <<<"$output")" = "fits" ]
}

@test "a 404 site is dead with an http reason" {
  export VERIFY_STUB_MAP="gone.example=404"
  run bash "$SUT" <<<'[{"name":"Gone","domain":"gone.example"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.dead' <<<"$output")" = "1" ]
  [ "$(jq -r '.dead[0].reason' <<<"$output")" = "http_404" ]
}

@test "a bot-walled 403 site is BLOCKED and kept, not dropped" {
  export VERIFY_STUB_MAP="walled.example=403"
  run bash "$SUT" <<<'[{"name":"Walled","domain":"walled.example"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.blocked' <<<"$output")" = "1" ]
  [ "$(jq -r '.blocked[0].verification' <<<"$output")" = "blocked" ]
  [ "$(jq -r '.stats.dead' <<<"$output")" = "0" ]
}

@test "a transient connect failure is retried and recovers to alive" {
  export VERIFY_STUB_MAP="flaky.example=FAILTHEN200"
  run bash "$SUT" <<<'[{"name":"Flaky","domain":"flaky.example"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.alive' <<<"$output")" = "1" ]
}

@test "a transient 503 is retried and recovers to alive" {
  export VERIFY_STUB_MAP="hiccup.example=503THEN200"
  run bash "$SUT" <<<'[{"name":"Hiccup","domain":"hiccup.example"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.alive' <<<"$output")" = "1" ]
}

@test "a persistent 5xx is BLOCKED, never terminal dead (dead gets ledgered forever)" {
  # dead[] flows into ledger.sh record-rejects as a PERMANENT reject — a
  # bot-wall served as 503 or a flaky origin must not be suppressed forever.
  export VERIFY_STUB_MAP="erroring.example=503"
  run bash "$SUT" <<<'[{"name":"Erroring","domain":"erroring.example"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.blocked' <<<"$output")" = "1" ]
  [ "$(jq -r '.stats.dead' <<<"$output")" = "0" ]
}

@test "a persistent connect failure is dead with reason connect_failed" {
  export VERIFY_STUB_MAP="dark.example=FAIL,alive.example=200,alive2.example=200"
  run bash "$SUT" <<<'[
    {"name":"Dark","domain":"dark.example"},
    {"name":"Alive","domain":"alive.example"},
    {"name":"Alive2","domain":"alive2.example"}
  ]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.dead' <<<"$output")" = "1" ]
  [ "$(jq -r '.dead[0].reason' <<<"$output")" = "connect_failed" ]
  [ "$(jq -r '.stats.alive' <<<"$output")" = "2" ]
}

@test "ALL candidates failing to connect is a network suspect, not a verdict" {
  export VERIFY_STUB_MAP="a.example=FAIL,b.example=FAIL,c.example=FAIL"
  run bash "$SUT" <<<'[
    {"name":"A","domain":"a.example"},
    {"name":"B","domain":"b.example"},
    {"name":"C","domain":"c.example"}
  ]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"VERIFY_NETWORK_SUSPECT"* ]]
}

@test "fewer than 3 all-failing candidates still resolve as dead (no false network alarm)" {
  export VERIFY_STUB_MAP="a.example=FAIL"
  run bash "$SUT" <<<'[{"name":"A","domain":"a.example"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.dead' <<<"$output")" = "1" ]
}

@test "empty input yields a well-formed empty result" {
  run bash "$SUT" <<<'[]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stats.checked' <<<"$output")" = "0" ]
}

@test "non-array stdin is rejected" {
  run bash "$SUT" <<<'{"not":"an array"}'
  [ "$status" -eq 1 ]
}
