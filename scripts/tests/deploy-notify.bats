#!/usr/bin/env bats
#
# scripts/lib/deploy-notify.sh — the deploy/rollback pager.
#
# WHY THIS EXISTS: slack_notify is deliberately best-effort — a MISSING token
# returns 0 (`slack_load_env ... || return 0`) and the send ends in `|| true`.
# So `slack_notify "$msg" || warn` can never warn, and deploy.yml's failure
# notification looked wired while being incapable of reporting its own failure.
# deploy-notify.sh must return non-zero on a send that did not land, or the
# 2026-08-06 class of silent outage repeats one level up.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/lib/deploy-notify.sh"
  TMP="$BATS_TEST_TMPDIR/case"
  mkdir -p "$TMP/bin"

  # Stub muso; MUSO_STUB_RC decides whether the "send" succeeds.
  cat > "$TMP/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MUSO_STUB_LOG:-/dev/null}"
exit "${MUSO_STUB_RC:-0}"
STUB
  chmod +x "$TMP/bin/muso"
  export PATH="$TMP/bin:$PATH"
  export MUSO_BIN="$TMP/bin/muso"
  export MUSO_STUB_LOG="$TMP/muso.log"
  # Satisfy slack_load_env without touching /etc/openclaw.
  export MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-test"
  export MUSO_SLACK_ENV_FILE="$TMP/nonexistent.env"
}

@test "returns 0 when the send succeeds" {
  MUSO_STUB_RC=0 run bash "$SCRIPT" success "hello"
  [ "$status" -eq 0 ]
}

@test "returns NON-ZERO when Slack rejects the send" {
  # The whole point: a rejected delivery (invalid_auth, not_in_channel — the
  # muso CLI decodes Slack's HTTP-200 {"ok":false} trap into a non-zero exit)
  # must surface. slack_notify would have returned 0 here.
  MUSO_STUB_RC=1 run bash "$SCRIPT" critical "boom"
  [ "$status" -ne 0 ]
}

@test "returns NON-ZERO when the bot token is absent" {
  # slack_load_env fails -> _slack_post_payload returns 1. slack_notify would
  # have returned 0 and the caller would have reported success.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  MUSO_STUB_RC=0 run env -u MUSO_SLACK_BOT_TOKEN_DEVOPS bash "$SCRIPT" success "hi"
  [ "$status" -ne 0 ]
}

@test "critical mode sends REAL <@UID> mentions, not a literal @name" {
  MUSO_STUB_RC=0 run bash "$SCRIPT" critical "deploy died"
  [ "$status" -eq 0 ]
  grep -q '<@U0AL36NADEY>' "$MUSO_STUB_LOG"
  grep -q '<@U7RP6HKUZ>' "$MUSO_STUB_LOG"
  ! grep -q '<@aaron>' "$MUSO_STUB_LOG"
}

@test "success mode does not ping anyone" {
  MUSO_STUB_RC=0 run bash "$SCRIPT" success "all good"
  [ "$status" -eq 0 ]
  ! grep -q '<@U' "$MUSO_STUB_LOG"
}

@test "rejects a bad mode and an empty message" {
  run bash "$SCRIPT" bogus "x"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" success ""
  [ "$status" -eq 2 ]
}

@test "returns NON-ZERO when the slack library is missing" {
  DEPLOY_NOTIFY_LIB="$TMP/nope.sh" run bash "$SCRIPT" success "hi"
  [ "$status" -ne 0 ]
}
