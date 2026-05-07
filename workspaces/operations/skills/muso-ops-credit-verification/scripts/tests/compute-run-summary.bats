#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# compute-run-summary.sh tests. See scripts/compute-run-summary.sh for
# rationale. The helper derives `run_finished` counters from the harness-
# recorded session JSONL, so these tests build realistic session fixtures
# (toolCall + toolResult pairs in the shape openclaw writes) and verify the
# helper's output and side-effects.

PROBE_URL="https://musicbrainz.org/artist/9fff2f8a-21e6-47de-a2b8-7f449929d43f"
PROBE_TEXT="Drake · MusicBrainz · Artist page"   # contains "musicbrainz" and "drake"

setup() {
  setup_tmp_env
  export SESSION_LOG="$TEST_TMPDIR/session.jsonl"
  : > "$SESSION_LOG"
  export CV_SESSION_LOG_OVERRIDE="$SESSION_LOG"
  export RUN_ID="20260420-120000-deadbe"
  export PARENT_MSG_TS="1776691677.022189"
  day="${RUN_ID:0:8}"
  RUNLOG_DIR="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$RUNLOG_DIR"
  export RUNLOG_FILE="$RUNLOG_DIR/${RUN_ID}.jsonl"
  : > "$RUNLOG_FILE"
  # All existing tests model the B6 terminal call (compute-run-summary.sh
  # invoked at the end of a run with the agent expecting invariant
  # detection — silent_failure, hollow, ungrounded). Set OPS_BATCH_TERMINAL=1
  # so the in-flight guard added 2026-04-28 (Failure 2 fix) does NOT short-
  # circuit these scenarios. Tests for the guard itself unset this in their
  # own bodies.
  export OPS_BATCH_TERMINAL=1
}
teardown() { teardown_tmp_env; }

# ---- session JSONL seeding helpers ----

seed_browser() {
  # args: call_id url is_error text
  local id="$1" url="$2" is_error="$3" text="$4"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg url "$url" \
    '{message:{role:"assistant",content:[{type:"toolCall",id:$id,name:"browser",arguments:{url:$url}}]}}')" >> "$SESSION_LOG"
  printf '%s\n' "$(jq -n -c --arg id "$id" --argjson err "$is_error" --arg text "$text" \
    '{message:{role:"toolResult",toolCallId:$id,isError:$err,content:[{type:"text",text:$text}]}}')" >> "$SESSION_LOG"
}

seed_browser_ok() { seed_browser "$1" "$2" "false" "${3:-$PROBE_TEXT}"; }

seed_exec_admin() {
  # args: call_id command-string response-body-text
  local id="$1" cmd="$2" text="$3"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg cmd "$cmd" \
    '{message:{role:"assistant",content:[{type:"toolCall",id:$id,name:"exec",arguments:{command:$cmd}}]}}')" >> "$SESSION_LOG"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg text "$text" \
    '{message:{role:"toolResult",toolCallId:$id,isError:false,content:[{type:"text",text:$text}]}}')" >> "$SESSION_LOG"
}

seed_exec_admin_err() {
  # Tool-layer error (timeout, crash) — response has isError=true and typically
  # no http_status in the text.
  local id="$1" cmd="$2" text="${3:-timeout after 30s}"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg cmd "$cmd" \
    '{message:{role:"assistant",content:[{type:"toolCall",id:$id,name:"exec",arguments:{command:$cmd}}]}}')" >> "$SESSION_LOG"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg text "$text" \
    '{message:{role:"toolResult",toolCallId:$id,isError:true,content:[{type:"text",text:$text}]}}')" >> "$SESSION_LOG"
}

seed_web_fetch() {
  local id="$1" url="$2" text="${3:-generic page body}"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg url "$url" \
    '{message:{role:"assistant",content:[{type:"toolCall",id:$id,name:"web_fetch",arguments:{url:$url}}]}}')" >> "$SESSION_LOG"
  printf '%s\n' "$(jq -n -c --arg id "$id" --arg text "$text" \
    '{message:{role:"toolResult",toolCallId:$id,isError:false,content:[{type:"text",text:$text}]}}')" >> "$SESSION_LOG"
}

seed_runlog_action() {
  local action="$1" cr_id="$2"
  jq -n -c --arg ev "action_attempted" --arg rid "$RUN_ID" \
          --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg a "$action" --arg id "$cr_id" \
    '{event:$ev,run_id:$rid,ts:$ts,action:$a,cr_id:$id}' >> "$RUNLOG_FILE"
}

seed_runlog_escalation() {
  local cr_id="$1"
  jq -n -c --arg ev "escalation_posted" --arg rid "$RUN_ID" \
          --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg id "$cr_id" \
    '{event:$ev,run_id:$rid,ts:$ts,cr_id:$id}' >> "$RUNLOG_FILE"
}

# ---- env / missing-input tests ----

@test "missing OPS_RUNLOG_DIR exits 2" {
  unset OPS_RUNLOG_DIR
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 2 ]
}

@test "missing OPS_WORKSPACE exits 2" {
  unset OPS_WORKSPACE
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 2 ]
}

@test "missing RUN_ID exits 2" {
  run "$SCRIPTS_DIR/compute-run-summary.sh" "" "$PARENT_MSG_TS"
  [ "$status" -eq 2 ]
}

@test "missing session log exits 3" {
  export CV_SESSION_LOG_OVERRIDE="/nonexistent/path/nope.jsonl"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 3 ]
}

@test "missing runlog file exits 5 (B0c init must precede B6)" {
  seed_browser_ok "c0" "$PROBE_URL"
  rm -f "$RUNLOG_FILE"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 5 ]
}

# ---- well-formed runs ----

@test "well-formed run: preflight + 2 approved + 1 verification_needed" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"},{"id":"11111111-2222-3333-4444-555555555555"},{"id":"99999999-8888-7777-6666-555555555555"}]}}'
  seed_exec_admin "c2" \
    'bash muso-admin-api.sh call PUT /admin/credit-requests --evidence-excerpt "x" {"requestIds":["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],"status":"approved"}' \
    '{"http_status":200,"body":{"result":"ok"}}'
  seed_exec_admin "c3" \
    'bash muso-admin-api.sh call PUT /admin/credit-requests --evidence-excerpt "y" {"requestIds":["11111111-2222-3333-4444-555555555555"],"status":"approved"}' \
    '{"http_status":200,"body":{"result":"ok"}}'
  seed_exec_admin "c4" \
    'bash muso-admin-api.sh call PUT /admin/credit-requests {"requestIds":["99999999-8888-7777-6666-555555555555"],"status":"user_verification_needed","reason":"suspicious"}' \
    '{"http_status":200,"body":{"result":"ok"}}'

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == true'
  echo "$output" | jq -e '.fetched == 3'
  echo "$output" | jq -e '.approved == 2'
  echo "$output" | jq -e '.verification_needed == 1'
  echo "$output" | jq -e '.errors == 0'
  echo "$output" | jq -e '.hollow == false'
  echo "$output" | jq -e '.ungrounded == false'
  echo "$output" | jq -e '.summary_post_message_ts == "1776691677.022189"'
  # derived_from is now an object mapping provenance → fields.
  echo "$output" | jq -e '.derived_from.session_jsonl | index("fetched") != null'
  echo "$output" | jq -e '.derived_from.runlog | index("escalated") != null'

  [ -f "$RUNLOG_FILE" ]
  jq -e 'select(.event=="run_finished" and .fetched==3 and .approved==2)' < "$RUNLOG_FILE"
  ! jq -e 'select(.event=="run_finished_hollow")' < "$RUNLOG_FILE" > /dev/null || return 1
  ! jq -e 'select(.event=="run_finished_ungrounded")' < "$RUNLOG_FILE" > /dev/null || return 1
}

# ---- incident-shape tests ----

@test "hollow run (14:51 51e6a2 style): preflight ok but zero admin-API calls" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_browser_ok "c1" "https://musicbrainz.org/artist/decoy"
  seed_exec_admin "c2" "bash some-other-script.sh --unrelated" '{"ok":true}'

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == true'
  echo "$output" | jq -e '.fetched == 0'
  echo "$output" | jq -e '.hollow == true'
  echo "$output" | jq -e '.ungrounded == false'

  jq -e 'select(.event=="run_finished_hollow")' < "$RUNLOG_FILE"
  jq -e 'select(.event=="run_finished_hollow" and (.tool_inventory.browser == 2))' < "$RUNLOG_FILE"
  # Hollow payload is self-contained — carries counters alongside the reason.
  jq -e 'select(.event=="run_finished_hollow" and .fetched == 0 and .approved == 0)' < "$RUNLOG_FILE"
}

@test "ungrounded run (13:26 b8b0e5 style): web_fetch substituted for probe + fake approve" {
  # Agent used web_fetch for the probe URL (not browser). Then faked an
  # approved PUT. Derived preflight is false; ungrounded invariant fires.
  seed_web_fetch "c0" "$PROBE_URL" "Drake musicbrainz page"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}'
  seed_exec_admin "c2" \
    'bash muso-admin-api.sh call PUT /admin/credit-requests --evidence-excerpt "fake" {"requestIds":["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],"status":"approved"}' \
    '{"http_status":200,"body":{"result":"ok"}}'

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == false'
  echo "$output" | jq -e '.approved == 1'
  echo "$output" | jq -e '.hollow == false'
  echo "$output" | jq -e '.ungrounded == true'

  jq -e 'select(.event=="run_finished_ungrounded")' < "$RUNLOG_FILE"
  jq -e 'select(.event=="run_finished_ungrounded" and .approved == 1)' < "$RUNLOG_FILE"
}

@test "preflight-failed run: browser tool errored on probe" {
  seed_browser "c0" "$PROBE_URL" "true" "timeout"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == false'
  echo "$output" | jq -e '.hollow == false'
  echo "$output" | jq -e '.ungrounded == false'
}

# ---- preflight semantic tests (B0d spec parity) ----

@test "preflight: Cloudflare challenge page with non-error response is rejected" {
  # A Cloudflare page can return HTTP 200 with non-empty body that lacks
  # "musicbrainz" and "drake" — B0d explicitly requires both.
  seed_browser "c0" "$PROBE_URL" "false" "Please wait while we verify you are human."
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == false'
}

@test "preflight: text containing only 'musicbrainz' (not 'drake') is rejected" {
  seed_browser "c0" "$PROBE_URL" "false" "Open Spotify · Error page"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == false'
}

@test "preflight: probe URL with trailing slash is accepted" {
  seed_browser_ok "c0" "${PROBE_URL}/"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == true'
}

@test "preflight: probe URL with tracking query is accepted" {
  seed_browser_ok "c0" "${PROBE_URL}?si=abc123"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == true'
}

# ---- fetched-id extraction tests ----

@test "fetched ignores nested id fields (track.id, user.id etc)" {
  # Realistic shape: each list item carries nested objects with their own ids.
  # Only top-level items[].id should count.
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","track":{"id":"55555555-6666-7777-8888-999999999999"},"user":{"id":"33333333-4444-5555-6666-777777777777"}}]}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 1'
}

@test "single-record GET (idempotency check in Step 2) does not inflate fetched" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}'
  seed_exec_admin "c2" \
    "bash muso-admin-api.sh call GET /admin/credit-requests/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" \
    '{"http_status":200,"body":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"unverified","claimName":"x"}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 1'
}

@test "fetched de-dupes credit IDs across multiple list pages" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=5" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"},{"id":"11111111-2222-3333-4444-555555555555"}]}}'
  seed_exec_admin "c2" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=5" \
    '{"http_status":200,"body":{"items":[{"id":"11111111-2222-3333-4444-555555555555"},{"id":"99999999-8888-7777-6666-555555555555"}]}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 3'
}

@test "cr_-prefixed credit IDs are recognized alongside UUIDs" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"cr_abc123def456"},{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 2'
}

@test "uppercase hex UUIDs are recognized (case-insensitive extraction)" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"}]}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 1'
}

# ---- error-counting tests ----

@test "http 4xx on credit-requests PUT counts as an error" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}'
  seed_exec_admin "c2" \
    'bash muso-admin-api.sh call PUT /admin/credit-requests {"requestIds":["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],"status":"approved"}' \
    '{"http_status":400,"body":{"result":"error","code":400,"message":"Unavailable service"}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 1'
  echo "$output" | jq -e '.approved == 0'
  echo "$output" | jq -e '.errors == 1'
}

@test "http 5xx on credit-requests PUT counts as an error" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}'
  seed_exec_admin "c2" \
    'bash muso-admin-api.sh call PUT /admin/credit-requests {"requestIds":["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],"status":"approved"}' \
    '{"http_status":502,"body":{"result":"error","code":502}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.errors == 1'
  echo "$output" | jq -e '.approved == 0'
}

@test "tool-errored admin-API call counts as an error (timeout / crash)" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin_err "c1" \
    "bash muso-admin-api.sh call PUT /admin/credit-requests {\"requestIds\":[\"aaa\"],\"status\":\"approved\"}" \
    "timeout after 30s — no response from upstream"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.errors == 1'
  echo "$output" | jq -e '.approved == 0'
}

@test "partial-success batch: 2 approvals succeed, 1 returns 500" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c_list" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"},{"id":"11111111-2222-3333-4444-555555555555"},{"id":"99999999-8888-7777-6666-555555555555"}]}}'
  seed_exec_admin "c_a" \
    'bash muso-admin-api.sh call PUT /admin/credit-requests {"requestIds":["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],"status":"approved"}' \
    '{"http_status":200,"body":{}}'
  seed_exec_admin "c_b" \
    'bash muso-admin-api.sh call PUT /admin/credit-requests {"requestIds":["11111111-2222-3333-4444-555555555555"],"status":"approved"}' \
    '{"http_status":200,"body":{}}'
  seed_exec_admin "c_c" \
    'bash muso-admin-api.sh call PUT /admin/credit-requests {"requestIds":["99999999-8888-7777-6666-555555555555"],"status":"approved"}' \
    '{"http_status":500,"body":{}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.approved == 2'
  echo "$output" | jq -e '.errors == 1'
}

# ---- runlog-sourced counter tests ----

@test "skipped_idempotent and skipped_cap are read from the runlog" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}'
  seed_runlog_action "skip_idempotent" "cr_old1"
  seed_runlog_action "skip_idempotent" "cr_old2"
  seed_runlog_action "skip_cap" "cr_capped"

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.skipped_idempotent == 2'
  echo "$output" | jq -e '.skipped_cap == 1'
}

@test "escalated is read from escalation_posted runlog events, deduped by cr_id" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}'
  seed_runlog_escalation "cr_esc1"
  seed_runlog_escalation "cr_esc2"
  seed_runlog_escalation "cr_esc1"   # duplicate — must not double-count

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.escalated == 2'
}

# ---- robustness tests ----

@test "malformed session JSONL lines are skipped and counted in parse_errors" {
  seed_browser_ok "c0" "$PROBE_URL"
  printf 'not valid json\n' >> "$SESSION_LOG"
  printf '{"truncated":\n' >> "$SESSION_LOG"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 1'
  # Parse errors are surfaced — not silently swallowed.
  echo "$output" | jq -e '.session_parse_errors >= 2'
}

@test "corrupt runlog is fatal, not silently zeroed" {
  seed_browser_ok "c0" "$PROBE_URL"
  printf 'GARBAGE LINE\n' >> "$RUNLOG_FILE"
  seed_runlog_action "skip_cap" "cr_1"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  # Non-zero exit — the helper must not silently report skipped_cap=0.
  [ "$status" -ne 0 ]
}

@test "non-admin-API exec calls are ignored" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" "bash some-helper.sh --flag" '{"http_status":200,"body":"unrelated"}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 0'
  echo "$output" | jq -e '.approved == 0'
  echo "$output" | jq -e '.hollow == true'
}

@test "fetched handles the real admin-API shape (body.data.items)" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"result":"ok","code":200,"data":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","workspaceId":"wwwwwwww-1111-2222-3333-444444444444","track":{"id":"tttttttt-5555-6666-7777-888888888888"},"user":{"id":"uuuuuuuu-9999-aaaa-bbbb-cccccccccccc"}},{"id":"12121212-3434-5656-7878-909090909090","track":{"id":"rrrrrrrr-1111-1111-1111-111111111111"}}]}}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 2'
}

@test "bundled exec: one bash block does approve + VN in sequence (tee pattern)" {
  # Realistic pattern from the 2026-04-20 14:20 batch — one exec call wraps
  # both an approve PUT and a VN PUT. Each admin-api call emits its own
  # http_status envelope into the combined stdout via `| tee`.
  seed_browser_ok "c0" "$PROBE_URL"
  # List fetch (separate exec)
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"data":{"items":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"},{"id":"11111111-2222-3333-4444-555555555555"}]}}}'
  # Bundled exec: approve CR-a (fails with 400), then VN CR-b (succeeds 200).
  seed_exec_admin "c2" \
    'bash muso-admin-api.sh call PUT /admin/credit-requests --evidence-excerpt "x" {"requestIds":["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],"status":"approved"} | tee /tmp/r1.json
bash muso-admin-api.sh call PUT /admin/credit-requests {"requestIds":["11111111-2222-3333-4444-555555555555"],"status":"user_verification_needed","reason":"suspicious"} | tee /tmp/r2.json' \
    'Credit 1 approve attempt:
{"http_status":400,"body":{"result":"error","code":400,"message":"Unavailable service"}}
Credit 1 result: HTTP 400
---
Credit 2 VN attempt:
{"http_status":200,"body":{"result":"ok"}}
Credit 2 result: HTTP 200'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 2'
  echo "$output" | jq -e '.approved == 0'        # approve failed
  echo "$output" | jq -e '.verification_needed == 1'  # VN succeeded
  echo "$output" | jq -e '.errors == 1'           # the 400
}

# ---- OPS_DRY_RUN summary annotation (issue #145) ----
# When a run was initialized with OPS_DRY_RUN=1, runlog.sh init stamps a
# run_header with dryRun:true. compute-run-summary MUST read that header
# first (source of truth = the log) and only fall back to env if absent.
# Consumers get a single dryRun bool and compute any human-facing prefix
# themselves — no redundant summary_label field.

seed_runlog_header() {
  # Write a run_header event with the given dryRun value to the runlog file.
  local dry="$1"
  jq -n -c --arg rid "$RUN_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson d "$dry" \
    '{event:"run_header", run_id:$rid, ts:$ts, dryRun:$d}' >> "$RUNLOG_FILE"
}

@test "dryRun:true flows into run_finished when run_header says dryRun:true" {
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_header true
  # Env deliberately NOT set — proves header is the source of truth.
  unset OPS_DRY_RUN
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.dryRun == true'
  # summary_label is gone — callers compute any prefix from .dryRun.
  echo "$output" | jq -e 'has("summary_label") | not'
  # Written event mirrors the stdout summary
  jq -e 'select(.event == "run_finished") | .dryRun == true' "$RUNLOG_FILE"
}

@test "dryRun:false in run_finished when no run_header and env is unset" {
  seed_browser_ok "c0" "$PROBE_URL"
  unset OPS_DRY_RUN
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.dryRun == false'
  echo "$output" | jq -e 'has("summary_label") | not'
}

@test "run_header dryRun:true takes precedence over OPS_DRY_RUN=0 env" {
  # Scenario: agent exported OPS_DRY_RUN=1 at B0c (header stamped), then env
  # got reset before B6. Without this, the summary would disagree with the
  # header and post-hoc review would see dryRun:true run_header +
  # dryRun:false run_finished.
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_header true
  OPS_DRY_RUN=0 run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.dryRun == true'
}

@test "env fallback applies when no run_header is present" {
  # Defensive: historical runs (pre-this-PR) have no run_header at all. The
  # env fallback keeps behavior sensible for those cases and for any fresh
  # run where the header didn't land.
  seed_browser_ok "c0" "$PROBE_URL"
  # No seed_runlog_header call — RUNLOG_FILE has no run_header line.
  OPS_DRY_RUN=1 run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.dryRun == true'
}

# ---- Reconciliation: results.jsonl as authoritative source (PR 2) ----
#
# PR #158 adds a truth-floor results.jsonl inside muso-admin-api.sh that is
# written for every /admin/credit-requests write regardless of caller
# redirection. These tests assert that compute-run-summary.sh prefers that
# file over session-derived counts when it exists, and fires the
# silent_failure_detected invariant when attempts > 0 but nothing landed —
# the exact 2026-04-22 19:15 lie shape.

# Helper: write a single line to the run-scoped results.jsonl.
seed_results() {
  # args: intended_status outcome request_ids_json
  local status="$1" outcome="$2" ids="$3"
  local path="$CV_RESULTS_PATH"
  mkdir -p "$(dirname "$path")"
  jq -n -c --arg s "$status" --arg o "$outcome" --argjson ids "$ids" --arg rid "$RUN_ID" \
    '{ts:"2026-04-22T19:19:00Z", run_id:$rid, method:"PUT", path:"/admin/credit-requests",
       request_ids:$ids, intended_status:$s, outcome:$o,
       http_status:(if $o == "ok" or $o == "dry_run_intercept" then 200 else null end),
       error:null, requester:null}' >> "$path"
}

setup_cv_results() {
  # Point CV_RESULTS_PATH at a tmp file so we don't write to /var/log in CI.
  export CV_RESULTS_PATH="$TEST_TMPDIR/credit-results.jsonl"
}

@test "reconciliation: results.jsonl absent → source=session_jsonl_fallback, silent_failure_detected=false" {
  # No results.jsonl exists. Fall through to legacy session-derived counts.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.source == "session_jsonl_fallback"'
  # Defaults: no attempts logged, no failure detected.
  echo "$output" | jq -e '.silent_failure_detected == false'
  echo "$output" | jq -e '.reconciliation.approved_attempted == 0'
  # Legacy session count still populates the top-level approved field.
  echo "$output" | jq -e '.approved == 0'
}

@test "reconciliation: results.jsonl present → source=results_jsonl, counts match file" {
  # Happy path: agent ran batch-approve-credits.sh and it succeeded.
  # Dry-run intercept is the mode: counts as "landed" for Slack purposes.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_results approved dry_run_intercept '["cr_1","cr_2","cr_3"]'
  seed_results user_verification_needed dry_run_intercept '["cr_4"]'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.source == "results_jsonl"'
  echo "$output" | jq -e '.reconciliation.approved_attempted == 3'
  echo "$output" | jq -e '.reconciliation.approved_landed == 3'
  echo "$output" | jq -e '.reconciliation.verification_needed_attempted == 1'
  echo "$output" | jq -e '.reconciliation.verification_needed_landed == 1'
  echo "$output" | jq -e '.approved == 3'
  echo "$output" | jq -e '.verification_needed == 1'
  echo "$output" | jq -e '.silent_failure_detected == false'
}

@test "reconciliation: batch PUT with 124 request_ids counts as 124 approved (not 1)" {
  # Real-world shape: one PUT /admin/credit-requests with N ids. request_ids
  # length is what matters for the Slack number, not invocation count.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  # Build a 124-id array.
  ids=$(jq -n -c '[range(0;124) | "cr_" + tostring]')
  seed_results approved dry_run_intercept "$ids"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.approved == 124'
  echo "$output" | jq -e '.reconciliation.approved_landed == 124'
}

@test "SILENT FAILURE INVARIANT: all approves rejected_by_gate → silent_failure_detected=true" {
  # The EXACT 2026-04-22 19:15 scenario replayed through the truth floor:
  # 333 approves attempted, all rejected by the gate (body-only evidence).
  # Slack prose claimed success; the invariant catches the lie.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  # T L A: 124 approves rejected
  ids_tla=$(jq -n -c '[range(0;124) | "tla_" + tostring]')
  seed_results approved rejected_by_gate "$ids_tla"
  # André Six: 11 approves rejected
  ids_as=$(jq -n -c '[range(0;11) | "as_" + tostring]')
  seed_results approved rejected_by_gate "$ids_as"
  # 167 UVN landed (actual 19:19 number)
  ids_uvn=$(jq -n -c '[range(0;167) | "uvn_" + tostring]')
  seed_results user_verification_needed dry_run_intercept "$ids_uvn"

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.silent_failure_detected == true'
  echo "$output" | jq -e '.approved == 0'
  echo "$output" | jq -e '.reconciliation.approved_attempted == 135'
  echo "$output" | jq -e '.reconciliation.approved_rejected_by_gate == 135'
  # UVN is fine — the invariant fires on APPROVE silent failure alone.
  echo "$output" | jq -e '.verification_needed == 167'

  # run_finished_silent_failure event lands in the runlog.
  jq -e 'select(.event=="run_finished_silent_failure")' < "$RUNLOG_FILE"
  jq -e 'select(.event=="run_finished_silent_failure" and .reconciliation.approved_rejected_by_gate == 135)' < "$RUNLOG_FILE"
}

@test "silent_failure_detected: fires for UVN attempts with zero landed too" {
  # Symmetry: UVN has no gate but could still suffer network failures or
  # http_error. If 0 of N UVN attempts landed, that's silent failure.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_results user_verification_needed http_error '["uvn_1","uvn_2","uvn_3"]'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.silent_failure_detected == true'
  echo "$output" | jq -e '.reconciliation.verification_needed_attempted == 3'
  echo "$output" | jq -e '.reconciliation.verification_needed_landed == 0'
  echo "$output" | jq -e '.reconciliation.verification_needed_http_error == 3'
}

@test "silent_failure_detected: false when ANY approves land (partial success still counts as alive)" {
  # 2 of 3 approved, 1 rejected → not silent failure. Truth in the numbers
  # is enough; partial failures are surfaced via reconciliation.approved_*
  # fields, not an invariant.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_results approved ok '["cr_1","cr_2"]'
  seed_results approved rejected_by_gate '["cr_3"]'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.silent_failure_detected == false'
  echo "$output" | jq -e '.approved == 2'
  echo "$output" | jq -e '.reconciliation.approved_attempted == 3'
  echo "$output" | jq -e '.reconciliation.approved_rejected_by_gate == 1'
}

@test "silent_failure_detected: false when attempted == 0 (no work to silently fail)" {
  # Empty batch (queue was drained or filtered to nothing). No invariant
  # should fire — we didn't try anything, we didn't lie about anything.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  # Touch the file so reconciliation runs, but don't add any lines.
  : > "$CV_RESULTS_PATH"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.silent_failure_detected == false'
  echo "$output" | jq -e '.reconciliation.approved_attempted == 0'
  echo "$output" | jq -e '.reconciliation.source == "results_jsonl"'
}

# ---- Read-side silent-zero (2026-04-27 incident class) ----
#
# The 2026-04-27 10:06 UTC dry-run posted "Queue clear — 0 unverified" while
# the live API had 13891 unverified credits. Root cause: agent's improvised
# B1 jq paths (`.body.items // .items // []`) silently fell through to `[]`
# because the real envelope is `.body.data.items`. The PRIMARY defense is
# `fetch-queue.sh`'s exit-11 invariant (caught at fetch time before any bad
# summary is computed). The BACKSTOP defense — these tests — fires inside
# compute-run-summary.sh when run_started_queue.queue_depth_at_start says
# the queue was non-empty but session-derived fetched is 0. This catches
# any future B1 code path that bypasses fetch-queue.sh.

@test "READ-SIDE SILENT-ZERO INVARIANT: queue_depth>0 but session fetched=0 → silent_failure_detected=true" {
  # Replay the 2026-04-27 shape AS IF B1 had logged the truth:
  #   - run_started_queue.queue_depth_at_start = 13891 (counts API was right)
  #   - session JSONL has no successful list response (improv jq returned [])
  # Note today's incident actually logged queue_depth=0 because the agent's
  # bash also misread counts. With fetch-queue.sh in place, queue_depth
  # comes from the locked path, so this hypothetical (script-bypassed-but-
  # counts-still-logged-correctly) is what the backstop covers.
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 13891
  # Crucially: NO seed_exec_admin for the list fetch — session has nothing.
  # Without our fix, the R2-6 fallback would set FETCHED=500 (queue<fetch),
  # and silent_failure_detected would stay false. The new SESSION_DERIVED_
  # FETCHED capture preserves the raw 0 for the silent-zero check.
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.silent_failure_detected == true'

  # run_finished_silent_failure event lands in the runlog with the new reason.
  jq -e 'select(.event=="run_finished_silent_failure" and (.reason | test("read_side_silent_zero")))' < "$RUNLOG_FILE"
  jq -e 'select(.event=="run_finished_silent_failure" and (.reason | test("queue_depth_at_start=13891")))' < "$RUNLOG_FILE"
}

@test "read-side silent-zero: false when queue_depth==0 (genuine empty queue)" {
  # The legitimate "queue clear" path. queue_depth=0 with fetched=0 is fine.
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 0
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.silent_failure_detected == false'
}

@test "read-side silent-zero: false when session DID observe items (truncation case)" {
  # The 2026-04-23 truncation class — queue_depth=12008, fetched parsed as
  # the real number from session JSONL — must NOT trip the read-side check.
  # Session-derived fetched > 0 means the fetch worked; only the run_finished
  # SUMMARY needs the R2-6 fallback for accurate Slack totals.
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 12008
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=500" \
    '{"http_status":200,"body":{"data":{"items":[{"id":"a"},{"id":"b"},{"id":"c"}]}}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.silent_failure_detected == false'
}

@test "read-side silent-zero: false when runlog profile groups prove fetch succeeded" {
  # Current CLI-batch shape: queue JSON is persisted to a temp file instead
  # of printed in full, so session-derived fetched can be 0. The runlog's
  # profile_group_fetched events prove B1 returned real items and B2 grouped
  # them, so the read-side silent-zero backstop must not fire.
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 13839
  jq -n -c --arg rid "$RUN_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{event:"profile_group_fetched", run_id:$rid, ts:$ts, profile_id:"p1", userid:"u1", cr_ids:["cr_1","cr_2"], count:2}' >> "$RUNLOG_FILE"

  setup_cv_results
  seed_results user_verification_needed ok '["cr_1","cr_2"]'

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.silent_failure_detected == false'
  echo "$output" | jq -e '.hollow == false'
  echo "$output" | jq -e '.verification_needed == 2'
  ! jq -e 'select(.event=="run_finished_silent_failure")' < "$RUNLOG_FILE" >/dev/null || return 1
  ! jq -e 'select(.event=="run_finished_hollow")' < "$RUNLOG_FILE" >/dev/null || return 1
}

@test "read-side silent-zero: write-side reason takes precedence when both fire" {
  # If the write-side check ALREADY flagged silent failure (rejected_by_gate
  # all-zero-landed), the read-side branch must NOT clobber the write-side
  # reason — the write-side incident class is more specific.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 13891
  seed_results approved rejected_by_gate '["cr_1","cr_2","cr_3"]'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.silent_failure_detected == true'
  # Write-side reason wins. Read-side reason MUST NOT appear.
  jq -e 'select(.event=="run_finished_silent_failure" and (.reason | test("admin-api attempts >0")))' < "$RUNLOG_FILE"
  ! jq -e 'select(.event=="run_finished_silent_failure" and (.reason | test("read_side_silent_zero")))' < "$RUNLOG_FILE" || return 1
}

@test "CLI preflight runlog event overrides missing session exec result" {
  # When a long-running exec is polled via openclaw's process tool, the
  # preflight-verify.sh stdout can land in a process result instead of the
  # original exec result. The helper-written runlog event is authoritative.
  jq -n -c --arg rid "$RUN_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{event:"preflight_ok", run_id:$rid, ts:$ts, probe_url:"https://musicbrainz.org/artist/9fff2f8a-21e6-47de-a2b8-7f449929d43f", source:"preflight-verify.sh@cli"}' >> "$RUNLOG_FILE"

  setup_cv_results
  seed_results user_verification_needed ok '["cr_1"]'

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == true'
  echo "$output" | jq -e '.hollow == false'
  echo "$output" | jq -e '.ungrounded == false'
}

@test "reconciliation: session_derived_approved preserved even when overridden" {
  # Post-mortem fidelity: if the agent's session JSONL-observed approves
  # disagree with the authoritative .results.jsonl number, both must be
  # visible. Session-observed lives under reconciliation.session_derived_*.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  # Session shows no actual 200 response (the > /dev/null pattern):
  # session-derived approved stays 0. Results.jsonl shows 5 landed.
  seed_results approved dry_run_intercept '["a","b","c","d","e"]'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.approved == 5'
  echo "$output" | jq -e '.reconciliation.session_derived_approved == 0'
}

# ---- Idempotency guard (R2-2) ----
#
# 2026-04-23 09:02 UTC produced two run_finished events because B3 and B6
# both explicitly invoked this script. The fix: if a run_finished event
# already exists for $RUN_ID in the runlog, return the cached summary and
# skip all event writes.

@test "idempotency: second invocation does not write duplicate run_finished events" {
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_results approved dry_run_intercept '["cr_1","cr_2"]'

  # First invocation: normal path, writes run_finished.
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  [ "$(jq -s 'map(select(.event == "run_finished")) | length' "$RUNLOG_FILE")" -eq 1 ]

  # Second invocation: cached path, no new writes.
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  [ "$(jq -s 'map(select(.event == "run_finished")) | length' "$RUNLOG_FILE")" -eq 1 ]
  # Also no silent_failure / hollow / ungrounded events written at all
  # (cached path skips all event writes, and fixture is the happy path).
  [ "$(jq -s 'map(select(.event == "run_finished_silent_failure")) | length' "$RUNLOG_FILE")" -eq 0 ]
}

@test "idempotency: second invocation returns the cached summary JSON identically" {
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_results approved dry_run_intercept '["cr_1","cr_2","cr_3"]'

  first_out=$("$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS")
  second_out=$("$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS")

  # Both invocations emit the same counts. The cached-path output is the
  # exact run_finished line from the runlog (which == the first_out payload
  # with .event/.ts/.run_id fields attached).
  [ "$(echo "$first_out" | jq -r '.approved')" = "$(echo "$second_out" | jq -r '.approved')" ]
  [ "$(echo "$first_out" | jq -r '.verification_needed')" = "$(echo "$second_out" | jq -r '.verification_needed')" ]
  [ "$(echo "$first_out" | jq -r '.reconciliation.source')" = "$(echo "$second_out" | jq -r '.reconciliation.source')" ]
}

@test "idempotency: cached path emits stderr note so re-invocations are visible post-mortem" {
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_results approved dry_run_intercept '["cr_1"]'

  "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS" >/dev/null
  # Second call — capture stderr separately.
  stderr_out=$("$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS" 2>&1 >/dev/null)
  [[ "$stderr_out" == *"run_finished already present"* ]]
  [[ "$stderr_out" == *"no new events written"* ]]
}

@test "idempotency: third+ invocations still stable (cached path fully idempotent)" {
  # Pathological: run 5 times. Runlog should still have exactly 1 run_finished.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_results approved dry_run_intercept '["cr_1"]'

  for _ in 1 2 3 4 5; do
    "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS" >/dev/null 2>&1
  done
  [ "$(jq -s 'map(select(.event == "run_finished")) | length' "$RUNLOG_FILE")" -eq 1 ]
}

@test "idempotency: invariant events from first run are preserved (not re-written)" {
  # Silent-failure invariant fires on first call. Second call must not
  # write a duplicate silent_failure event either.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  # All approves rejected → silent_failure_detected fires on first call.
  seed_results approved rejected_by_gate '["cr_1","cr_2","cr_3"]'

  "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS" >/dev/null
  [ "$(jq -s 'map(select(.event == "run_finished_silent_failure")) | length' "$RUNLOG_FILE")" -eq 1 ]

  "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS" >/dev/null
  # Still exactly 1 — cached path skipped all writes.
  [ "$(jq -s 'map(select(.event == "run_finished_silent_failure")) | length' "$RUNLOG_FILE")" -eq 1 ]
  [ "$(jq -s 'map(select(.event == "run_finished")) | length' "$RUNLOG_FILE")" -eq 1 ]
}

# ---- Fetched fallback (R2-6) ----
#
# The 2026-04-23 09:02 UTC dry-run had fetched:0 in the summary even though
# the agent processed 500 credits. Root cause: openclaw's exec tool truncated
# the list-response body (~500KB) to the last 16KB, slicing off the
# {"http_status":200,"body":{...}} envelope. session_counts.fetched saw no
# parseable items.
#
# Fallback: when session-derived FETCHED is 0, read the intended batch size
# from the run_started event and the queue depth from run_started_queue, and
# use min(fetch_size, queue_depth) as the authoritative "fetched" figure.

seed_runlog_run_started() {
  # args: fetch_size queue_depth (queue_depth optional — use "" to skip)
  local fs="$1" qd="${2:-}"
  jq -n -c --arg rid "$RUN_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson fs "$fs" \
    '{event:"run_started", run_id:$rid, ts:$ts, phase:"0", fetch_size:$fs}' >> "$RUNLOG_FILE"
  if [[ -n "$qd" ]]; then
    jq -n -c --arg rid "$RUN_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson qd "$qd" \
      '{event:"run_started_queue", run_id:$rid, ts:$ts, queue_depth_at_start:$qd}' >> "$RUNLOG_FILE"
  fi
}

@test "fetched fallback: when session-derived is 0 and response truncated, use run_started.fetch_size" {
  # Replay the 2026-04-23 shape: no parseable fetch in session JSONL,
  # runlog has fetch_size=500 and queue_depth=12008.
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 12008
  # No seed_exec_admin for the list fetch — simulating the truncated envelope.
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  # Queue (12008) >> fetch_size (500), so fetched = 500.
  echo "$output" | jq -e '.fetched == 500'
}

@test "fetched fallback: caps at queue_depth when queue_depth < fetch_size" {
  # Small queue edge case: fetch_size=500 but only 42 credits in queue.
  # Authoritative fetched = 42 (we can't fetch more than exist).
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 42
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 42'
}

@test "fetched fallback: session-derived takes precedence when > 0" {
  # If the session log DOES have a parseable fetch response, use it (we
  # know it's accurate). The fallback only kicks in for the truncated case.
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 12008
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"data":{"items":[{"id":"aa"},{"id":"bb"},{"id":"cc"}]}}}'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  # Session saw 3 items → 3 wins over the 500 fallback.
  echo "$output" | jq -e '.fetched == 3'
}

@test "fetched fallback: no run_started event → stays 0 (no invented number)" {
  # Defense-in-depth: if there's no run_started event either, the fallback
  # can't fabricate a number. Better to report 0 than guess.
  seed_browser_ok "c0" "$PROBE_URL"
  # No seed_runlog_run_started call — runlog only has our browser seed.
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 0'
}

@test "fetched fallback: run_started without queue_depth → uses fetch_size directly" {
  # Older runlog shape missing run_started_queue — fetch_size alone suffices.
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 250 ""
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 250'
}

# 2026-05-07: the manual @Ops batch (run 20260507-133229-7dd133) hit the
# audit's reconciliation invariant. The R2-6 fallback computed
# fetched=500 (run_started.fetch_size, the cap, not the actual fetch
# of 200 credits across 31 profile groups), but results.jsonl recorded
# only 250 actual attempts (82 approved + 168 UVN). Audit's
# `fetched - sum_buckets` returned mismatch=250, post-batch-summary.sh
# refused to post the canonical Slack summary, the agent improvised a
# [HEARTBEAT-BATCH] message, and the renderer-missing :rotating_light:
# alert correctly fired.
#
# Fix: when results.jsonl is the reconciliation source, re-derive
# FETCHED from the bucket sums it produced, so the audit's invariant
# `fetched == sum_buckets` holds by construction. Truncated
# session-derived fetched no longer leaks the fallback's overstated
# cap into Slack.

@test "fetched: results.jsonl source overrides fetch_size fallback to match sum_buckets" {
  # Replay the 13:32 UTC shape: list response truncated → session-derived
  # FETCHED stays 0 → R2-6 fallback would set 500 — but results.jsonl says
  # 250 actual attempts. New behavior: when results.jsonl is the source,
  # FETCHED = approved_attempted + UVN_attempted (+ escalated/skipped/errors).
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 20347
  # No seed_exec_admin — simulating the truncated envelope.
  # results.jsonl: 82 approved landed + 168 UVN landed.
  ids_appr=$(jq -n -c '[range(0;82) | "appr_" + tostring]')
  ids_uvn=$(jq -n -c '[range(0;168) | "uvn_" + tostring]')
  seed_results approved ok "$ids_appr"
  seed_results user_verification_needed ok "$ids_uvn"

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  # fetched now matches sum_buckets (250) — not the overstated 500 fallback.
  echo "$output" | jq -e '.reconciliation.source == "results_jsonl"'
  echo "$output" | jq -e '.fetched == 250'
  echo "$output" | jq -e '.approved == 82'
  echo "$output" | jq -e '.verification_needed == 168'
  # Reconciliation invariant: audit's mismatch = fetched - sum_buckets = 0.
  echo "$output" | jq -e '(.fetched - (.approved + .verification_needed + .escalated + .skipped_idempotent + .skipped_cap + .errors)) == 0'
}

@test "fetched: results.jsonl source — empty attempts AND truncated session falls through to fetch_size" {
  # Defensive: when results.jsonl exists but is empty (no attempts logged),
  # the override guard `_rj_sum > 0` keeps the legacy fetch_size fallback.
  # Otherwise we'd zero out a legitimate truncated fetch and silence
  # signal that work happened.
  setup_cv_results
  : > "$CV_RESULTS_PATH"  # empty file → source=results_jsonl, sum=0
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 12008
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.source == "results_jsonl"'
  # _rj_sum == 0, guard skips the override, R2-6 fallback wins.
  echo "$output" | jq -e '.fetched == 500'
}

@test "fetched: results.jsonl source preserves session-derived fetched when it's accurate" {
  # When the session log DID parse cleanly (small-batch happy path),
  # session-derived FETCHED already equals sum_buckets and the override
  # is a no-op. Regression guard for the existing happy-path semantics.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"data":{"items":[{"id":"cr_1"},{"id":"cr_2"},{"id":"cr_3"}]}}}'
  seed_results approved ok '["cr_1","cr_2"]'
  seed_results user_verification_needed ok '["cr_3"]'
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.source == "results_jsonl"'
  echo "$output" | jq -e '.fetched == 3'   # session-derived 3 == sum_buckets 3
  echo "$output" | jq -e '.approved == 2'
  echo "$output" | jq -e '.verification_needed == 1'
}

@test "fetched: results.jsonl source — session-derived diverges from results buckets, results wins" {
  # Edge: if the session log shows 5 items fetched but results.jsonl recorded
  # 7 attempts (e.g. retries, or a fetch went through a different path), the
  # results.jsonl truth-floor takes precedence so the audit's reconciliation
  # holds. The session-derived count remains in `derived_from` for forensics.
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  seed_exec_admin "c1" \
    "bash muso-admin-api.sh call GET /admin/credit-requests?status=unverified&limit=10" \
    '{"http_status":200,"body":{"data":{"items":[{"id":"a"},{"id":"b"},{"id":"c"},{"id":"d"},{"id":"e"}]}}}'
  ids_appr=$(jq -n -c '[range(0;4) | "appr_" + tostring]')
  ids_uvn=$(jq -n -c '[range(0;3) | "uvn_" + tostring]')
  seed_results approved ok "$ids_appr"
  seed_results user_verification_needed ok "$ids_uvn"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fetched == 7'
  echo "$output" | jq -e '(.fetched - (.approved + .verification_needed)) == 0'
}

# --- R3-final: rejected_pre_flight bucket ------------------------------------
#
# batch-verify-profile.sh writes rows with outcome=rejected_pre_flight when
# its local pre-flight refuses (missing Tier-1 evidence OR in-run web_fetch
# contamination). These are a distinct failure class from gate rejections —
# the agent never reached the gate because its evidence-gathering step
# didn't supply what was needed. Surface as its own reconciliation field so
# Slack consumers can distinguish "the agent tried and was caught" from
# "the agent never even attempted the HTTP call".

@test "reconciliation: rejected_pre_flight rows surface as distinct bucket" {
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  # Simulate the 2026-04-23 12:57 UTC shape: 30 profiles × avg ~3 credits =
  # 102 approve attempts pre-flight-refused because per-profile evidence
  # wasn't loaded. This is the shape we want the reconciliation to show,
  # NOT rejected_by_gate.
  ids_batch=$(jq -n -c '[range(0;102) | "cr_" + tostring]')
  jq -n -c --arg rid "$RUN_ID" --argjson ids "$ids_batch" \
    '{ts:"2026-04-23T12:57:30Z", run_id:$rid, method:"PUT", path:"/admin/credit-requests",
       request_ids:$ids, intended_status:"approved",
       outcome:"rejected_pre_flight", pre_flight:"missing_evidence",
       http_status:null, error:null, requester:null}' >> "$CV_RESULTS_PATH"

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.approved_attempted == 102'
  echo "$output" | jq -e '.reconciliation.approved_rejected_pre_flight == 102'
  echo "$output" | jq -e '.reconciliation.approved_rejected_by_gate == 0'
  # rejected_pre_flight also counts as a silent failure (0 landed of 102).
  echo "$output" | jq -e '.silent_failure_detected == true'
}

@test "reconciliation: rejected_pre_flight rows from web_fetch_tier1 contamination" {
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  jq -n -c --arg rid "$RUN_ID" \
    '{ts:"2026-04-23T12:57:30Z", run_id:$rid, method:"PUT", path:"/admin/credit-requests",
       request_ids:["cr_a","cr_b"], intended_status:"approved",
       outcome:"rejected_pre_flight", pre_flight:"web_fetch_tier1",
       http_status:null, error:null, requester:null}' >> "$CV_RESULTS_PATH"

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.approved_rejected_pre_flight == 2'
}

@test "reconciliation: pre_flight and gate buckets are independent" {
  setup_cv_results
  seed_browser_ok "c0" "$PROBE_URL"
  # Mixed batch: some pre-flight-refused, some gate-rejected, some landed.
  jq -n -c --arg rid "$RUN_ID" \
    '{ts:"2026-04-23T12:57:30Z", run_id:$rid, method:"PUT", path:"/admin/credit-requests",
       request_ids:["cr_1","cr_2"], intended_status:"approved",
       outcome:"rejected_pre_flight", pre_flight:"missing_evidence",
       http_status:null, error:null, requester:null}' >> "$CV_RESULTS_PATH"
  seed_results approved rejected_by_gate '["cr_3","cr_4","cr_5"]'
  seed_results approved dry_run_intercept '["cr_6"]'

  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.approved_attempted == 6'
  echo "$output" | jq -e '.reconciliation.approved_landed == 1'
  echo "$output" | jq -e '.reconciliation.approved_rejected_pre_flight == 2'
  echo "$output" | jq -e '.reconciliation.approved_rejected_by_gate == 3'
  # 1 of 6 landed — not all-zero, so silent_failure is false.
  echo "$output" | jq -e '.silent_failure_detected == false'
}


# ---- In-flight guard (Failure 2 from 2026-04-28 15:35:00 UTC) ----
#
# When the agent splits B0+B1 and B2+ across multiple exec calls, the bash
# trap-on-EXIT in exec 1 historically fired lockfile.sh release, which
# invoked compute-run-summary.sh as a crash-recovery fallback. That wrote
# run_finished_hollow + run_finished_silent_failure 53s before B2 actually
# ran. Compute-run-summary.sh now refuses to write run_finished if
# queue_depth_at_start > 0 AND zero action_attempted events, unless the
# caller passes --final or sets OPS_BATCH_TERMINAL=1.

@test "in-flight guard: refuses without --final when queue_depth>0 and attempts==0 (exit 8)" {
  unset OPS_BATCH_TERMINAL
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 13864
  run --separate-stderr "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 8 ]
  [[ "$stderr" == *"refusing to write run_finished"* ]]
  [[ "$stderr" == *"queue_depth_at_start=13864"* ]]
  [[ "$stderr" == *"action_attempted=0"* ]]
  # No run_finished event written.
  ! jq -e 'select(.event=="run_finished")' < "$RUNLOG_FILE" >/dev/null 2>&1 || return 1
}

@test "in-flight guard: --final flag overrides and writes run_finished" {
  unset OPS_BATCH_TERMINAL
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 13864
  run "$SCRIPTS_DIR/compute-run-summary.sh" --final "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  # silent_failure_detected fires (queue_depth>0 but session-derived fetched=0)
  echo "$output" | jq -e '.silent_failure_detected == true'
  jq -e 'select(.event=="run_finished")' < "$RUNLOG_FILE" >/dev/null
}

@test "in-flight guard: OPS_BATCH_TERMINAL=1 env overrides the same way --final does" {
  unset OPS_BATCH_TERMINAL
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 13864
  OPS_BATCH_TERMINAL=1 run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  jq -e 'select(.event=="run_finished")' < "$RUNLOG_FILE" >/dev/null
}

@test "in-flight guard: empty queue (queue_depth_at_start==0) is not blocked even without --final" {
  # Empty-queue case is NOT in-flight — no work to do, immediate run_finished
  # with hollow=false, fetched=0 is the correct shape. Guard must not fire.
  unset OPS_BATCH_TERMINAL
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 0
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  jq -e 'select(.event=="run_finished")' < "$RUNLOG_FILE" >/dev/null
}

@test "in-flight guard: action_attempted seeded → not blocked even without --final" {
  unset OPS_BATCH_TERMINAL
  seed_browser_ok "c0" "$PROBE_URL"
  seed_runlog_run_started 500 13864
  seed_runlog_action approve "cr_1"
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  jq -e 'select(.event=="run_finished")' < "$RUNLOG_FILE" >/dev/null
}
