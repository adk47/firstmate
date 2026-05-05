#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
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

seed_result_plugin_blocked() {
  # args: call_id
  # Shape observed in 2026-04-23 14:20 UTC session log: the enforcer plugin
  # returns isError:false with details.status=error + the block explanation.
  local id="$1"
  printf '%s\n' "$(jq -n -c --arg id "$id" \
    '{message: {role:"toolResult", toolCallId:$id, isError:false,
                content:[{type:"text", text:"{\"status\":\"error\",\"tool\":\"web_fetch\",\"error\":\"web_fetch is disabled on Tier 1 music-data hosts during credit verification.\"}"}],
                details:{status:"error", tool:"web_fetch", error:"web_fetch is disabled..."}}}')" >> "$SESSION_LOG"
}

@test "emits empty block when no session log exists" {
  CV_SESSION_LOG_OVERRIDE=/nonexistent/path run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.browser_loads == [] and .browser_errors == [] and .count_ok == 0 and .count_err == 0 and .session_log == null'
}

@test "counts a single successful browser load" {
  seed_toolcall "c1" "browser" "https://musicbrainz.org/artist/drake"
  seed_result_ok "c1" "<html><title>Drake on Spotify</title></html>"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 1 and .count_err == 0'
  echo "$output" | jq -e '.browser_loads[0].url == "https://musicbrainz.org/artist/drake"'
  echo "$output" | jq -e '.browser_loads[0].host == "musicbrainz.org"'
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
  seed_toolcall "c1" "web_fetch" "https://musicbrainz.org/artist/should-not-count"
  seed_result_ok "c1" "fetched body"
  seed_toolcall "c2" "browser" "https://musicbrainz.org/artist/real"
  seed_result_ok "c2" "real body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 1'
  echo "$output" | jq -e '.browser_loads[0].url == "https://musicbrainz.org/artist/real"'
}

@test "mixed successes and errors produce accurate counts" {
  seed_toolcall "c1" "browser" "https://musicbrainz.org/artist/a"
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
  seed_toolcall "c1" "browser" "https://musicbrainz.org/artist/pending"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 0 and .count_err == 0'
}

@test "malformed JSONL lines are skipped without failing the run" {
  printf 'not valid json\n' >> "$SESSION_LOG"
  seed_toolcall "c1" "browser" "https://musicbrainz.org/artist/resilient"
  seed_result_ok "c1" "ok"
  printf '{"truncated":\n' >> "$SESSION_LOG"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 1'
}

@test "output is valid JSON fit for pasting into a Slack fenced block" {
  seed_toolcall "c1" "browser" "https://musicbrainz.org/artist/json-safe"
  seed_result_ok "c1" 'body with "quotes" and \backslashes\\'
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  # Must round-trip through jq without error.
  echo "$output" | jq -e '.' > /dev/null
}

# --- R3-3: CV_SESSION_RUN_STARTED_TS filter ------------------------------
#
# openclaw channel-keys sessions: one file spans multiple runs. The gate's
# old behavior (mtime-bounded only) meant yesterday's browser loads + web_fetch
# calls still counted today. CV_SESSION_RUN_STARTED_TS scopes the scan to the
# current run's time window so past activity is structurally excluded.

seed_toolcall_at() {
  # args: timestamp call_id tool_name url
  local ts="$1" id="$2" name="$3" url="$4"
  printf '%s\n' "$(jq -n -c --arg ts "$ts" --arg id "$id" --arg name "$name" --arg url "$url" \
    '{type:"message", timestamp:$ts, message: {role:"assistant", content:[{type:"toolCall", id:$id, name:$name, arguments:{url:$url}}]}}')" >> "$SESSION_LOG"
}

seed_result_ok_at() {
  local ts="$1" id="$2" text="$3"
  printf '%s\n' "$(jq -n -c --arg ts "$ts" --arg id "$id" --arg text "$text" \
    '{type:"message", timestamp:$ts, message: {role:"toolResult", toolCallId:$id, isError:false, content:[{type:"text", text:$text}]}}')" >> "$SESSION_LOG"
}

@test "CV_SESSION_RUN_STARTED_TS filters out older browser_loads (evidence mode)" {
  seed_toolcall_at "2026-04-22T10:00:00Z" "c_old" "browser" "https://musicbrainz.org/artist/old"
  seed_result_ok_at "2026-04-22T10:00:01Z" "c_old" "old body"
  seed_toolcall_at "2026-04-23T12:00:00Z" "c_new" "browser" "https://musicbrainz.org/artist/new"
  seed_result_ok_at "2026-04-23T12:00:01Z" "c_new" "new body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" CV_SESSION_RUN_STARTED_TS="2026-04-23T11:00:00Z" \
    run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 1'
  echo "$output" | jq -e '.browser_loads[0].url == "https://musicbrainz.org/artist/new"'
}

@test "CV_SESSION_RUN_STARTED_TS unset → no filtering (backward compat)" {
  seed_toolcall_at "2026-04-22T10:00:00Z" "c_old" "browser" "https://musicbrainz.org/artist/old"
  seed_result_ok_at "2026-04-22T10:00:01Z" "c_old" "old body"
  seed_toolcall_at "2026-04-23T12:00:00Z" "c_new" "browser" "https://musicbrainz.org/artist/new"
  seed_result_ok_at "2026-04-23T12:00:01Z" "c_new" "new body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 2'
}

@test "CV_SESSION_RUN_STARTED_TS set, line has no .timestamp → line excluded" {
  # Safer default: untimestamped lines can't prove they belong to current run.
  seed_toolcall "c_untimed" "browser" "https://musicbrainz.org/artist/untimed"
  seed_result_ok "c_untimed" "body"
  seed_toolcall_at "2026-04-23T12:00:00Z" "c_new" "browser" "https://musicbrainz.org/artist/new"
  seed_result_ok_at "2026-04-23T12:00:01Z" "c_new" "body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" CV_SESSION_RUN_STARTED_TS="2026-04-23T11:00:00Z" \
    run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 1'
  echo "$output" | jq -e '.browser_loads[0].url == "https://musicbrainz.org/artist/new"'
}

@test "CV_SESSION_RUN_STARTED_TS boundary is inclusive (entry at exact ts counts)" {
  seed_toolcall_at "2026-04-23T11:00:00Z" "c_edge" "browser" "https://musicbrainz.org/artist/edge"
  seed_result_ok_at "2026-04-23T11:00:00Z" "c_edge" "body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" CV_SESSION_RUN_STARTED_TS="2026-04-23T11:00:00Z" \
    run "$SCRIPTS_DIR/session-evidence.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.count_ok == 1'
}

# --- R3-1a: --check-tier1-webfetch mode ----------------------------------
#
# B0d.5 uses this to abort the batch BEFORE B1 when the session has already
# been contaminated by a web_fetch to a Tier-1 host. Fails faster than the
# gate, with a clear Slack message path.

@test "--check-tier1-webfetch exit 0 on a clean session (browser only)" {
  seed_toolcall "c1" "browser" "https://musicbrainz.org/artist/a"
  seed_result_ok "c1" "body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 0 ]
}

@test "--check-tier1-webfetch exit 0 when web_fetch is to a non-Tier-1 host" {
  seed_toolcall "c1" "web_fetch" "https://example.com/something"
  seed_result_ok "c1" "body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 0 ]
}

@test "--check-tier1-webfetch exit 1 + stderr names host on Tier-1 contamination" {
  seed_toolcall "c1" "web_fetch" "https://musicbrainz.org/artist/bad"
  seed_result_ok "c1" "body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run --separate-stderr "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"musicbrainz.org"* ]]
  [[ "$stderr" == *"Tier"* ]]
}

@test "--check-tier1-webfetch lists all distinct offending hosts" {
  seed_toolcall "c1" "web_fetch" "https://musicbrainz.org/artist/x"
  seed_result_ok "c1" "body1"
  seed_toolcall "c2" "web_fetch" "https://musicbrainz.org/artist/y"
  seed_result_ok "c2" "body2"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run --separate-stderr "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"musicbrainz.org"* ]]
  [[ "$stderr" == *"musicbrainz.org"* ]]
}

@test "--check-tier1-webfetch dedupes repeated fetches to same host" {
  seed_toolcall "c1" "web_fetch" "https://musicbrainz.org/artist/one"
  seed_result_ok "c1" "body1"
  seed_toolcall "c2" "web_fetch" "https://musicbrainz.org/artist/two"
  seed_result_ok "c2" "body2"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run --separate-stderr "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 1 ]
  # Host appears exactly once in the stderr bullet list.
  local host_lines
  host_lines=$(echo "$stderr" | grep -c '^  - musicbrainz.org$' || true)
  [ "$host_lines" = "1" ]
}

@test "--check-tier1-webfetch on missing session log → exit 0 (nothing to contaminate)" {
  CV_SESSION_LOG_OVERRIDE=/nonexistent/path run "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 0 ]
}

@test "--check-tier1-webfetch ignores www. prefix when matching hosts" {
  seed_toolcall "c1" "web_fetch" "https://www.musicbrainz.org/artist/x"
  seed_result_ok "c1" "body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run --separate-stderr "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"musicbrainz.org"* ]]
}

@test "--check-tier1-webfetch ignores browser calls to Tier-1 (only web_fetch is contamination)" {
  seed_toolcall "c1" "browser" "https://musicbrainz.org/artist/legit"
  seed_result_ok "c1" "body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 0 ]
}

@test "--check-tier1-webfetch + CV_SESSION_RUN_STARTED_TS → old web_fetch ignored" {
  # Yesterday's contamination must not poison today's run when scope applied.
  seed_toolcall_at "2026-04-22T10:00:00Z" "c_old" "web_fetch" "https://musicbrainz.org/artist/contaminated"
  seed_result_ok_at "2026-04-22T10:00:01Z" "c_old" "body"
  seed_toolcall_at "2026-04-23T12:00:00Z" "c_new" "browser" "https://musicbrainz.org/artist/new"
  seed_result_ok_at "2026-04-23T12:00:01Z" "c_new" "body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" CV_SESSION_RUN_STARTED_TS="2026-04-23T11:00:00Z" \
    run "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 0 ]
}

@test "--check-tier1-webfetch + CV_SESSION_RUN_STARTED_TS → new web_fetch still caught" {
  seed_toolcall_at "2026-04-23T12:05:00Z" "c_bad" "web_fetch" "https://musicbrainz.org/artist/new-bad"
  seed_result_ok_at "2026-04-23T12:05:01Z" "c_bad" "body"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" CV_SESSION_RUN_STARTED_TS="2026-04-23T11:00:00Z" \
    run --separate-stderr "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"musicbrainz.org"* ]]
}

@test "unknown flag → exit 2" {
  run "$SCRIPTS_DIR/session-evidence.sh" --no-such-flag
  [ "$status" -eq 2 ]
}

# --- R4-1: --check-tier1-webfetch skips blocked/errored web_fetch results ---
#
# Mirrors the gate's R4-1 fix. A plugin-blocked web_fetch (or a 404/timeout)
# did not actually fetch Tier-1 data, so it should NOT trigger the
# contamination alarm. Only a web_fetch that returned real Tier-1 content
# is a risk.

@test "R4-1: --check-tier1-webfetch ignores plugin-blocked web_fetch" {
  seed_toolcall "wf" "web_fetch" "https://musicbrainz.org/artist/drake"
  seed_result_plugin_blocked "wf"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 0 ]
}

@test "R4-1: --check-tier1-webfetch still flags successful web_fetch to Tier-1" {
  # The genuine contamination case — non-regression.
  seed_toolcall "wf" "web_fetch" "https://musicbrainz.org/artist/drake"
  seed_result_ok "wf" "<html>Drake - Spotify artist page real data</html>"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run --separate-stderr "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"musicbrainz.org"* ]]
}

@test "R4-1: --check-tier1-webfetch ignores errored (isError=true) web_fetch" {
  seed_toolcall "wf" "web_fetch" "https://allmusic.com/artist/gone"
  seed_result_error "wf"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 0 ]
}

@test "R4-1: --check-tier1-webfetch ignores empty-content web_fetch result" {
  seed_toolcall "wf" "web_fetch" "https://discogs.com/artist/x"
  seed_result_empty "wf"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 0 ]
}

@test "R4-1: --check-tier1-webfetch flags only the successful call in a mix" {
  # Plugin-blocked tidal + successful musicbrainz → flag musicbrainz only.
  seed_toolcall "wf1" "web_fetch" "https://tidal.com/album/drake"
  seed_result_plugin_blocked "wf1"
  seed_toolcall "wf2" "web_fetch" "https://musicbrainz.org/search?q=x"
  seed_result_ok "wf2" "<html>MusicBrainz search results real data</html>"
  CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" run --separate-stderr "$SCRIPTS_DIR/session-evidence.sh" --check-tier1-webfetch
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"musicbrainz.org"* ]]
  [[ "$stderr" != *"tidal.com"* ]]
}
