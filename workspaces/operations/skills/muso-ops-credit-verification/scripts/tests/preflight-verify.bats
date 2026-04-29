#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# preflight-verify.sh runs the browser probe through the openclaw CLI. These
# tests stub openclaw on PATH and assert both the runlog contract and the exact
# CLI probe shape.

PROBE_URL="https://open.spotify.com/artist/3TVXtAsR1Inumwj472S9r4"
SNAPSHOT_OK='RootWebArea "Drake | Spotify"'

setup() {
  setup_tmp_env
  export RUN_ID="20260420-120000-deadbe"
  day="${RUN_ID:0:8}"
  RUNLOG_DIR="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$RUNLOG_DIR"
  export RUNLOG_FILE="$RUNLOG_DIR/${RUN_ID}.jsonl"
  : > "$RUNLOG_FILE"

  export CV_PROBE_HYDRATION_SLEEP=0
  export OPS_OPENCLAW_PROFILE="test"
  export OPENCLAW_CALLS="$TEST_TMPDIR/openclaw.calls"
  export OPENCLAW_SNAPSHOT_TEXT="$SNAPSHOT_OK"
  export OPENCLAW_OPEN_RC=0
  export OPENCLAW_SNAPSHOT_RC=0
  install_openclaw_stub
}
teardown() { teardown_tmp_env; }

install_openclaw_stub() {
  local bin_dir
  bin_dir="$TEST_TMPDIR/bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OPENCLAW_CALLS"

case "$*" in
  *" browser open "*)
    if [[ "${OPENCLAW_OPEN_RC:-0}" -ne 0 ]]; then
      echo "${OPENCLAW_OPEN_ERR:-browser open exploded}" >&2
      exit "$OPENCLAW_OPEN_RC"
    fi
    echo "opened"
    ;;
  *" browser snapshot "*)
    if [[ "${OPENCLAW_SNAPSHOT_RC:-0}" -ne 0 ]]; then
      echo "${OPENCLAW_SNAPSHOT_ERR:-snapshot exploded}" >&2
      exit "$OPENCLAW_SNAPSHOT_RC"
    fi
    printf '%s\n' "${OPENCLAW_SNAPSHOT_TEXT:-RootWebArea \"Drake | Spotify\"}"
    ;;
  *)
    echo "unexpected openclaw args: $*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$bin_dir/openclaw"
  export PATH="$bin_dir:$PATH"
}

assert_probe_calls() {
  grep -F -- "--profile test browser open $PROBE_URL" "$OPENCLAW_CALLS"
  grep -F -- "--profile test browser snapshot --format aria --limit 200" "$OPENCLAW_CALLS"
}

@test "missing OPS_RUNLOG_DIR exits 2" {
  unset OPS_RUNLOG_DIR
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 2 ]
}

@test "missing OPS_WORKSPACE exits 2" {
  unset OPS_WORKSPACE
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 2 ]
}

@test "missing RUN_ID exits 2" {
  run "$SCRIPTS_DIR/preflight-verify.sh" ""
  [ "$status" -eq 2 ]
}

@test "missing openclaw exits 2" {
  PATH="/usr/bin:/bin"
  run --separate-stderr "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"openclaw CLI not found"* ]]
}

@test "browser open failure exits 10 and writes failure event" {
  export OPENCLAW_OPEN_RC=42
  export OPENCLAW_OPEN_ERR="gateway refused browser open"

  run --separate-stderr "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
  [[ "$stderr" == *"PREFLIGHT_FAIL: browser open failed"* ]]
  jq -e 'select(.event=="preflight_browser_unavailable" and .error=="browser open failed" and .diagnostic=="gateway refused browser open" and .source=="preflight-verify.sh@cli")' < "$RUNLOG_FILE"
}

@test "browser snapshot failure exits 10 and writes failure event" {
  export OPENCLAW_SNAPSHOT_RC=43
  export OPENCLAW_SNAPSHOT_ERR="snapshot timeout"

  run --separate-stderr "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
  [[ "$stderr" == *"PREFLIGHT_FAIL: browser snapshot failed"* ]]
  jq -e 'select(.event=="preflight_browser_unavailable" and .error=="browser snapshot failed" and .diagnostic=="snapshot timeout" and .source=="preflight-verify.sh@cli")' < "$RUNLOG_FILE"
  assert_probe_calls
}

@test "snapshot marker-missing failure exits 10 and writes failure event" {
  export OPENCLAW_SNAPSHOT_TEXT='RootWebArea "Open Spotify"'

  run --separate-stderr "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
  [[ "$stderr" == *"lacks 'drake' and/or 'spotify' markers"* ]]
  jq -e 'select(.event=="preflight_browser_unavailable" and .error=="snapshot rendered but lacks '\''drake'\'' and/or '\''spotify'\'' markers" and .source=="preflight-verify.sh@cli")' < "$RUNLOG_FILE"
  assert_probe_calls
}

@test "successful probe exits 0, writes preflight_ok, and prints marker output" {
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PREFLIGHT_OK: probe markers present in snapshot"* ]]
  [[ "$output" == *"Drake | Spotify"* ]]
  jq -e 'select(.event=="preflight_ok" and .probe_url=="https://open.spotify.com/artist/3TVXtAsR1Inumwj472S9r4" and .source=="preflight-verify.sh@cli")' < "$RUNLOG_FILE"
  ! jq -e 'select(.event=="preflight_browser_unavailable")' < "$RUNLOG_FILE" > /dev/null
  assert_probe_calls
}

@test "success event payload carries source" {
  "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID" >/dev/null
  jq -e 'select(.event=="preflight_ok") | .source == "preflight-verify.sh@cli"' < "$RUNLOG_FILE"
}

@test "failure event payload carries source" {
  export OPENCLAW_SNAPSHOT_TEXT='RootWebArea "not enough markers"'
  "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID" >/dev/null 2>&1 || true
  jq -e 'select(.event=="preflight_browser_unavailable") | .source == "preflight-verify.sh@cli"' < "$RUNLOG_FILE"
}

@test "second invocation on a frozen run exits 20 from runlog freeze gate" {
  export OPENCLAW_SNAPSHOT_TEXT='RootWebArea "Open Spotify"'
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]

  local first_count second_count
  first_count=$(grep -c '"event":"preflight_browser_unavailable"' "$RUNLOG_FILE")
  [ "$first_count" -eq 1 ]

  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 20 ]
  second_count=$(grep -c '"event":"preflight_browser_unavailable"' "$RUNLOG_FILE")
  [ "$second_count" -eq 1 ]
}
