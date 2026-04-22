#!/usr/bin/env bats
load helpers

# compute-run-summary.sh tests. See scripts/compute-run-summary.sh for
# rationale. The helper derives `run_finished` counters from the harness-
# recorded session JSONL, so these tests build realistic session fixtures
# (toolCall + toolResult pairs in the shape openclaw writes) and verify the
# helper's output and side-effects.

PROBE_URL="https://open.spotify.com/artist/3TVXtAsR1Inumwj472S9r4"
PROBE_TEXT="Drake · Spotify · Artist page"   # contains "spotify" and "drake"

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
  ! jq -e 'select(.event=="run_finished_hollow")' < "$RUNLOG_FILE" > /dev/null
  ! jq -e 'select(.event=="run_finished_ungrounded")' < "$RUNLOG_FILE" > /dev/null
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
  seed_web_fetch "c0" "$PROBE_URL" "Drake spotify page"
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
  # "spotify" and "drake" — B0d explicitly requires both.
  seed_browser "c0" "$PROBE_URL" "false" "Please wait while we verify you are human."
  run "$SCRIPTS_DIR/compute-run-summary.sh" "$RUN_ID" "$PARENT_MSG_TS"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preflight_ok == false'
}

@test "preflight: text containing only 'spotify' (not 'drake') is rejected" {
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
