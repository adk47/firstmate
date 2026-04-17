#!/usr/bin/env bats
load helpers

setup() {
  setup_tmp_env
  export SESSION_LOG="$TEST_TMPDIR/session.jsonl"
  : > "$SESSION_LOG"
}
teardown() { teardown_tmp_env; }

# Helpers for seeding JSONL fixtures in the shape openclaw writes.
seed_toolcall() {
  # args: call_id tool_name url
  local id="$1" name="$2" url="$3"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg name "$name" --arg url "$url" \
    '{message: {role:"assistant", content:[{type:"toolCall", id:$id, name:$name, arguments:{url:$url}}]}}')" >> "$SESSION_LOG"
}

seed_result_ok() {
  # args: call_id text
  local id="$1" text="$2"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg text "$text" \
    '{message: {role:"toolResult", toolCallId:$id, isError:false, content:[{type:"text", text:$text}]}}')" >> "$SESSION_LOG"
}

seed_result_error() {
  # args: call_id
  local id="$1"
  printf '%s\n' "$(jq -n -c --arg id "$id" \
    '{message: {role:"toolResult", toolCallId:$id, isError:true, content:[{type:"text", text:"network error"}]}}')" >> "$SESSION_LOG"
}

seed_result_empty() {
  # args: call_id
  local id="$1"
  printf '%s\n' "$(jq -n -c --arg id "$id" \
    '{message: {role:"toolResult", toolCallId:$id, isError:false, content:[]}}')" >> "$SESSION_LOG"
}

@test "emits empty block when no session log exists" {
  CV_SESSION_LOG_OVERRIDE=/nonexistent/path run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.browser_loads == [] and .browser_errors == [] and .count_ok == 0 and .count_err == 0 and .session_log == null'
}

@test "counts a single successful browser load" {
  seed_toolcall "c1" "browser" "https://open.spotify.com/artist/drake"
  seed_result_ok "c1" "<html><title>Drake on Spotify</title></html>"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 1 and .count_err == 0'
  echo "$output" | jq -e '.browser_loads[0].url == "https://open.spotify.com/artist/drake"'
  echo "$output" | jq -e '.browser_loads[0].host == "open.spotify.com"'
  echo "$output" | jq -e '.browser_loads[0].ok == true'
}

@test "dedupes repeated loads of the same URL" {
  seed_toolcall "c1" "browser" "https://musicbrainz.org/artist/abc"
  seed_result_ok "c1" "page body 1"
  seed_toolcall "c2" "browser" "https://musicbrainz.org/artist/abc"
  seed_result_ok "c2" "page body 2"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 1'
  echo "$output" | jq -e '(.browser_loads | length) == 1'
}

@test "reports a toolResult marked isError as a browser_error" {
  seed_toolcall "c1" "browser" "https://discogs.com/artist/123"
  seed_result_error "c1"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 0 and .count_err == 1'
  echo "$output" | jq -e '.browser_errors[0].url == "https://discogs.com/artist/123"'
  echo "$output" | jq -e '.browser_errors[0].reason == "toolResult.isError=true"'
}

@test "reports an empty-content toolResult as a browser_error" {
  seed_toolcall "c1" "browser" "https://allmusic.com/artist/xyz"
  seed_result_empty "c1"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 0 and .count_err == 1'
  echo "$output" | jq -e '.browser_errors[0].reason == "no content returned"'
}

@test "ignores non-browser tool calls" {
  # web_fetch is explicitly forbidden by the skill — must not appear in evidence.
  seed_toolcall "c1" "web_fetch" "https://open.spotify.com/artist/should-not-count"
  seed_result_ok "c1" "fetched body"
  seed_toolcall "c2" "browser" "https://open.spotify.com/artist/real"
  seed_result_ok "c2" "real body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 1'
  echo "$output" | jq -e '.browser_loads[0].url == "https://open.spotify.com/artist/real"'
}

@test "mixed successes and errors produce accurate counts" {
  seed_toolcall "c1" "browser" "https://open.spotify.com/artist/a"
  seed_result_ok "c1" "ok body"
  seed_toolcall "c2" "browser" "https://musicbrainz.org/artist/b"
  seed_result_error "c2"
  seed_toolcall "c3" "browser" "https://tidal.com/artist/c"
  seed_result_ok "c3" "ok body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 2 and .count_err == 1'
  # Ensure the errored URL is NOT in browser_loads
  echo "$output" | jq -e '([.browser_loads[].url] | index("https://musicbrainz.org/artist/b")) == null'
}

@test "toolCall with no matching toolResult is ignored (in-flight call)" {
  # An orphan toolCall without a toolResult must not be counted either way.
  seed_toolcall "c1" "browser" "https://open.spotify.com/artist/pending"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 0 and .count_err == 0'
}

@test "malformed JSONL lines are skipped without failing the run" {
  printf 'not valid json\n' >> "$SESSION_LOG"
  seed_toolcall "c1" "browser" "https://open.spotify.com/artist/resilient"
  seed_result_ok "c1" "ok"
  printf '{"truncated":\n' >> "$SESSION_LOG"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 1'
}

@test "output is valid JSON fit for pasting into a Slack fenced block" {
  seed_toolcall "c1" "browser" "https://open.spotify.com/artist/json-safe"
  seed_result_ok "c1" 'body with "quotes" and \backslashes\\'
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  # Must round-trip through jq without error.
  echo "$output" | jq -e '.' > /dev/null
}
