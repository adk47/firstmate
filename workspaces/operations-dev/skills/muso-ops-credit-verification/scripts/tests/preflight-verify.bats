#!/usr/bin/env bats
load helpers

# preflight-verify.sh tests. The helper derives the B0d preflight outcome
# from session-JSONL evidence — same `probe_opened && probe_rendered` logic
# compute-run-summary.sh uses — then writes EITHER preflight_ok OR
# preflight_browser_unavailable to the runlog so the agent cannot hand-write
# the event.

PROBE_URL="https://open.spotify.com/artist/3TVXtAsR1Inumwj472S9r4"
PROBE_TEXT="Drake · Spotify · Artist page"

setup() {
  setup_tmp_env
  export SESSION_LOG="$TEST_TMPDIR/session.jsonl"
  : > "$SESSION_LOG"
  export CV_SESSION_LOG_OVERRIDE="$SESSION_LOG"
  export RUN_ID="20260420-120000-deadbe"
  day="${RUN_ID:0:8}"
  RUNLOG_DIR="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$RUNLOG_DIR"
  export RUNLOG_FILE="$RUNLOG_DIR/${RUN_ID}.jsonl"
  : > "$RUNLOG_FILE"
}
teardown() { teardown_tmp_env; }

# Seed a browser toolCall + toolResult pair.
seed_browser() {
  local id="$1" url="$2" is_error="$3" text="$4"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg url "$url" \
    '{message:{role:"assistant",content:[{type:"toolCall",id:$id,name:"browser",arguments:{url:$url}}]}}')" >> "$SESSION_LOG"
  printf '%s\n' "$(jq -n -c --arg id "$id" --argjson err "$is_error" --arg text "$text" \
    '{message:{role:"toolResult",toolCallId:$id,isError:$err,content:[{type:"text",text:$text}]}}')" >> "$SESSION_LOG"
}

seed_browser_ok() { seed_browser "$1" "$2" "false" "${3:-$PROBE_TEXT}"; }

seed_web_fetch() {
  local id="$1" url="$2" text="${3:-generic body}"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg url "$url" \
    '{message:{role:"assistant",content:[{type:"toolCall",id:$id,name:"web_fetch",arguments:{url:$url}}]}}')" >> "$SESSION_LOG"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg text "$text" \
    '{message:{role:"toolResult",toolCallId:$id,isError:false,content:[{type:"text",text:$text}]}}')" >> "$SESSION_LOG"
}

# ---- env / arg validation ----

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

@test "missing session log exits 3" {
  unset CV_SESSION_LOG_OVERRIDE
  # Override with a nonexistent path so the workspace-scoped find returns nothing.
  export CV_SESSION_LOG_OVERRIDE="$TEST_TMPDIR/does-not-exist.jsonl"
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 3 ]
}

# ---- happy path ----

@test "successful browser probe of Drake URL: exit 0, preflight_ok event" {
  seed_browser_ok "c0" "$PROBE_URL"
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == true'
  jq -e 'select(.event=="preflight_ok")' < "$RUNLOG_FILE"
  # No failure event written.
  ! jq -e 'select(.event=="preflight_browser_unavailable")' < "$RUNLOG_FILE" > /dev/null
}

@test "successful probe: event carries probe_url" {
  seed_browser_ok "c0" "$PROBE_URL"
  "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  jq -e '.probe_url == "https://open.spotify.com/artist/3TVXtAsR1Inumwj472S9r4"' < "$RUNLOG_FILE"
}

# ---- failure modes that must NOT log preflight_ok ----

@test "no browser tool calls at all: exit 10, preflight_browser_unavailable" {
  # Empty session — agent claims preflight passed but called no tools.
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
  echo "$output" | jq -e '.preflight_ok == false'
  jq -e 'select(.event=="preflight_browser_unavailable")' < "$RUNLOG_FILE"
  ! jq -e 'select(.event=="preflight_ok")' < "$RUNLOG_FILE" > /dev/null
}

@test "web_fetch substituted for browser: exit 10 (the 13:26 incident class)" {
  # Agent used web_fetch on the probe URL instead of browser. Must fail.
  seed_web_fetch "c0" "$PROBE_URL" "$PROBE_TEXT"
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
  echo "$output" | jq -e '.preflight_ok == false'
  jq -e 'select(.event=="preflight_browser_unavailable")' < "$RUNLOG_FILE"
}

@test "browser errored on probe: exit 10" {
  seed_browser "c0" "$PROBE_URL" "true" "timeout after 30s"
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
}

@test "browser opened probe but rendered text lacks 'drake': exit 10" {
  # Cloudflare challenge with spotify-ish markers but no 'drake'.
  seed_browser "c0" "$PROBE_URL" "false" "Open Spotify · verifying human"
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
}

@test "browser opened probe but rendered text lacks 'spotify': exit 10" {
  seed_browser "c0" "$PROBE_URL" "false" "Drake · unrelated artist dump"
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
}

@test "browser opened UNRELATED URL but rendered drake+spotify: exit 10" {
  # Agent loads a different page, then tries to pass off the content as probe.
  # probe_opened must target the probe URL.
  seed_browser "c0" "https://example.com/drake" "false" "$PROBE_TEXT"
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
}

# ---- tolerated URL variants (match compute-run-summary.sh) ----

@test "probe URL with trailing slash counts" {
  seed_browser_ok "c0" "${PROBE_URL}/"
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
}

@test "probe URL with query string counts" {
  seed_browser_ok "c0" "${PROBE_URL}?si=abc"
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
}

# ---- failure-event payload carries a short reason ----

@test "failure event has non-empty reason string" {
  seed_browser "c0" "$PROBE_URL" "true" "timeout"
  "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID" || true
  jq -e 'select(.event=="preflight_browser_unavailable") | .error | length > 0' < "$RUNLOG_FILE"
}

# ---- robustness: malformed JSONL + repeated invocation ----

@test "session log of pure garbage lines: exit 10, no crash" {
  # Verifies fromjson? // empty silently drops malformed lines instead of
  # propagating a jq parse error through set -e. Garbage-only logs must
  # produce a clean preflight_browser_unavailable, not a stack trace.
  printf 'not json\nstill not json {trailing\n%%%%\n' > "$SESSION_LOG"
  run "$SCRIPTS_DIR/preflight-verify.sh" "$RUN_ID"
  [ "$status" -eq 10 ]
  jq -e 'select(.event=="preflight_browser_unavailable")' < "$RUNLOG_FILE"
}

@test "second invocation on a frozen run: exit 20 from runlog freeze gate" {
  # If preflight-verify.sh is called a second time for an already-failed run,
  # its inner runlog.sh event call hits the freeze gate (exit 20). The contract:
  # the freeze propagates through set -euo pipefail, the second run does NOT
  # double-write, and a caller that loops on failure cannot accidentally clear
  # the freeze. (First call already established the failure event in setup.)
  seed_browser "c0" "$PROBE_URL" "true" "timeout"
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
