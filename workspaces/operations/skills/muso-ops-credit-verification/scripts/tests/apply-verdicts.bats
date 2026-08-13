#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

APPLY="$SCRIPTS_DIR/lobster-mvp/apply-verdicts.sh"

setup() {
  setup_tmp_env
  export FIXTURE="$TEST_TMPDIR/verdicts.json"
  cat > "$FIXTURE" <<'JSON'
{
  "queue_depth": 1,
  "fetch_size": 1,
  "counts": {"total":1,"would_approve":1,"would_uvn":0},
  "would_approve": [{"cr_id":"cr_1"}],
  "would_uvn": []
}
JSON

  export ADMIN_STUB="$TEST_TMPDIR/admin-api.sh"
  export ADMIN_CALLS="$TEST_TMPDIR/admin.calls"
  cat > "$ADMIN_STUB" <<'STUB'
#!/usr/bin/env bash
printf 'retries=%s delay=%s\n' \
  "${MUSO_ADMIN_PRECONNECT_RETRIES:-}" \
  "${MUSO_ADMIN_RETRY_DELAY_SECONDS:-}" >> "$ADMIN_CALLS"
case "${ADMIN_STUB_MODE:-ok}" in
  recovered_dns)
    printf '{"http_status":200,"body":{"ok":true},"transport_attempts":2,"transport_retry_exits":[6]}\n'
    ;;
  persistent_dns)
    echo 'WARN: simulated truth-floor write warning' >&2
    printf '{"http_status":null,"body":null,"transport_error":{"curl_exit":6,"attempts":2,"retry_exits":[6]}}\n'
    exit 6
    ;;
  timeout)
    printf '{"http_status":null,"body":null,"transport_error":{"curl_exit":28,"attempts":1,"retry_exits":[]}}\n'
    exit 28
    ;;
  http_500)
    printf '{"http_status":500,"body":{"error":"server"},"transport_attempts":1,"transport_retry_exits":[]}\n'
    ;;
  *)
    printf '{"http_status":200,"body":{"ok":true},"transport_attempts":1,"transport_retry_exits":[]}\n'
    ;;
esac
STUB
  chmod +x "$ADMIN_STUB"
}

teardown() { teardown_tmp_env; }

run_apply() {
  run --separate-stderr env \
    ADMIN_API_SH="$ADMIN_STUB" \
    ADMIN_STUB_MODE="$1" \
    OPS_LOBSTER_APPLY_LOG="$TEST_TMPDIR/apply.jsonl" \
    CV_APPLY_TRANSPORT_RETRY_DELAY_SECONDS=0 \
    bash -c "'$APPLY' false < '$FIXTURE'"
}

@test "apply opts into one pre-connect retry and records recovered DNS as landed" {
  run_apply recovered_dns
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .apply.approve.eligible == 1
    and .apply.approve.landed == 1
    and .apply.approve.refused == 0
    and .apply.approve.transport_failed == 0
    and .apply.transport_failed == 0
  ' >/dev/null
  grep -q '^retries=1 delay=0$' "$ADMIN_CALLS"
  jq -e 'select(.event == "approve_chunk_transport_retried" and .attempts == 2 and .recovered == true and .retry_exits == [6])' \
    "$TEST_TMPDIR/apply.jsonl" >/dev/null
}

@test "persistent DNS is transport_failed, never refused" {
  run_apply persistent_dns
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .apply.approve.eligible == 1
    and .apply.approve.landed == 0
    and .apply.approve.refused == 0
    and .apply.approve.transport_failed == 1
    and .apply.refused == 0
    and .apply.transport_failed == 1
    and .apply.approve.transport_failed_ids == [
      {"cr_id":"cr_1","reason":"transport_curl_6","curl_exit":6,"attempts":2}
    ]
  ' >/dev/null
  jq -e 'select(.event == "approve_chunk_transport_failed" and .curl_exit == 6 and .attempts == 2)' \
    "$TEST_TMPDIR/apply.jsonl" >/dev/null
}

@test "timeout is transport_failed without retry" {
  run_apply timeout
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .apply.approve.transport_failed == 1
    and .apply.approve.refused == 0
    and .apply.approve.transport_failed_ids[0].curl_exit == 28
    and .apply.approve.transport_failed_ids[0].attempts == 1
  ' >/dev/null
}

@test "HTTP 500 remains refused and is never a transport failure" {
  run_apply http_500
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .apply.approve.landed == 0
    and .apply.approve.refused == 1
    and .apply.approve.transport_failed == 0
    and .apply.approve.refused_ids == [{"cr_id":"cr_1","reason":"http_500"}]
  ' >/dev/null
}

@test "dry-run schema includes zero transport failures and never calls admin API" {
  run --separate-stderr env \
    ADMIN_API_SH="$ADMIN_STUB" \
    OPS_LOBSTER_APPLY_LOG="$TEST_TMPDIR/apply.jsonl" \
    bash -c "'$APPLY' true < '$FIXTURE'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .apply.dry_run == true
    and .apply.transport_failed == 0
    and .apply.approve.transport_failed == 0
    and .apply.uvn.transport_failed == 0
  ' >/dev/null
  [ ! -e "$ADMIN_CALLS" ]
}
