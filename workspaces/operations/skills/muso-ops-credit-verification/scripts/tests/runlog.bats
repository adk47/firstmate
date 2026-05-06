#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

setup() {
  setup_tmp_env
  export OPS_RUNLOG_DIR="$TEST_TMPDIR/credit-batch-runs"
  mkdir -p "$OPS_RUNLOG_DIR"
  # 2026-05-06 cutover: existing cases assert legacy browser-mode semantics
  # (preflight freeze on browser failure, count_profile_browser_loads,
  # tier1_unreachable bypass). Pin to browser so they keep covering the
  # rollback path. The default mode flipped to api with this cutover.
  export CV_EVIDENCE_MODE=browser
}
teardown() { teardown_tmp_env; }

@test "init creates run_id and writes latest.txt pointer" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]{6}$ ]]
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  [ -f "$LOG_FILE" ]
  [ "$(cat $OPS_RUNLOG_DIR/latest.txt)" = "$LOG_FILE" ]
}

@test "event appends a JSON line with ts and run_id" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" run_started \
    '{"phase":"0","fetch_size":10,"approval_cap_limit":500}'
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  # Line has event, run_id, ts, and fields
  jq -e '.event == "run_started" and .run_id != null and .ts != null and .phase == "0" and .fetch_size == 10' \
    < "$LOG_FILE"
}

@test "event preserves multiple appends in order" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" credit_fetched '{"cr_id":"cr_1"}'
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" credit_fetched '{"cr_id":"cr_2"}'
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" credit_fetched '{"cr_id":"cr_3"}'
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  # `wc -l` output differs on BSD (padded) vs GNU (unpadded); normalize with awk.
  [ "$(awk 'END{print NR}' "$LOG_FILE")" = "3" ]
  [ "$(jq -r '.cr_id' < $LOG_FILE | head -1)" = "cr_1" ]
  [ "$(jq -r '.cr_id' < $LOG_FILE | tail -1)" = "cr_3" ]
}

@test "fails with exit 2 when OPS_RUNLOG_DIR unset" {
  unset OPS_RUNLOG_DIR
  run "$SCRIPTS_DIR/runlog.sh" init
  [ "$status" -eq 2 ]
}

@test "event rejects invalid JSON payload (exit 3)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  run "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" test_event 'not json {'
  [ "$status" -eq 3 ]
}

@test "init returns distinct run_ids when called rapidly in same second" {
  # Two `init` calls in the same UTC second must not collide on the run_id.
  # Run IDs share the YYYYMMDD-HHMMSS prefix; the 6-hex suffix disambiguates.
  # If a future change drops the suffix (or shrinks it too small), this catches it.
  RUN_A=$("$SCRIPTS_DIR/runlog.sh" init)
  RUN_B=$("$SCRIPTS_DIR/runlog.sh" init)
  RUN_C=$("$SCRIPTS_DIR/runlog.sh" init)
  [ "$RUN_A" != "$RUN_B" ]
  [ "$RUN_B" != "$RUN_C" ]
  [ "$RUN_A" != "$RUN_C" ]
}

# ---- preflight_browser_unavailable gate ----
# Once preflight fails, SKILL.md B0d requires the turn to exit. The 2026-04-20
# 13:19 UTC manual run (2bfea8) bypassed this by logging
# preflight_browser_unavailable and then writing run_started phase="manual"
# to continue. This gate makes that mechanically impossible.

@test "event after preflight_browser_unavailable is refused (exit 20)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    '{"probe_url":"x","error":"timeout"}'
  run "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" run_started \
    '{"phase":"manual"}'
  [ "$status" -eq 20 ]
  # Error message identifies the gate so future readers can find it.
  [[ "$output" == *"preflight_browser_unavailable"* ]]
}

@test "gate blocks ANY subsequent event, not just run_started" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    '{"probe_url":"x","error":"timeout"}'
  for ev in credit_fetched verdict action_attempted action_result escalation_posted run_finished; do
    run "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" "$ev" '{"cr_id":"x"}'
    [ "$status" -eq 20 ]
  done
}

@test "gate does not affect OTHER runs" {
  # Only the run with preflight_browser_unavailable is frozen; a different
  # run (different RUN_ID, different file) is unaffected.
  RUN_A=$("$SCRIPTS_DIR/runlog.sh" init)
  RUN_B=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_A" preflight_browser_unavailable \
    '{"probe_url":"x","error":"timeout"}'
  # RUN_B must still accept events.
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_B" run_started '{"phase":"0"}'
  TODAY=$(date -u +%Y-%m-%d)
  LOG_B="$OPS_RUNLOG_DIR/$TODAY/$RUN_B.jsonl"
  jq -e 'select(.event=="run_started")' < "$LOG_B"
}

@test "writing preflight_browser_unavailable itself is allowed" {
  # The gate must not refuse the FIRST preflight_browser_unavailable —
  # otherwise preflight-verify.sh couldn't log the failure it detected.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" run_started '{"phase":"0"}'
  run "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    '{"probe_url":"x","error":"timeout"}'
  [ "$status" -eq 0 ]
}

@test "duplicate preflight_browser_unavailable is refused (already frozen)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    '{"probe_url":"x","error":"timeout"}'
  run "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    '{"probe_url":"x","error":"retry"}'
  [ "$status" -eq 20 ]
}

@test "events before preflight_browser_unavailable remain writable normally" {
  # Sanity: the gate is state-dependent, not blanket. run_started logged
  # BEFORE the failure must not poison unrelated events on other runs.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" run_started '{"phase":"0"}'
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" credit_fetched '{"cr_id":"cr_1"}'
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  [ "$(awk 'END{print NR}' "$LOG_FILE")" = "2" ]
}

# ---- OPS_DRY_RUN run header (issue #145) ----
# When OPS_DRY_RUN=1, `init` must tag the run so downstream consumers can
# detect dry-run from the log alone without re-reading env.

@test "init writes run_header with dryRun:true when OPS_DRY_RUN=1" {
  RUN_ID=$(OPS_DRY_RUN=1 OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID=C0T "$SCRIPTS_DIR/runlog.sh" init)
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  # First line is the header
  jq -e '.event == "run_header" and .dryRun == true' < <(head -1 "$LOG_FILE")
}

@test "init writes NO run_header when OPS_DRY_RUN is unset" {
  # Non-dry-run runs stay identical to historical behavior: the file is
  # created empty. No run_header event, no dryRun:false noise.
  unset OPS_DRY_RUN
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  [ ! -s "$LOG_FILE" ]
}

@test "init writes NO run_header when OPS_DRY_RUN=0" {
  OPS_DRY_RUN=0 RUN_ID=$(OPS_DRY_RUN=0 "$SCRIPTS_DIR/runlog.sh" init)
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  [ ! -s "$LOG_FILE" ]
}

@test "subsequent events still land after the dry-run run_header" {
  export OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID=C0DRYRUN
  RUN_ID=$(OPS_DRY_RUN=1 OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID=C0DRYRUN "$SCRIPTS_DIR/runlog.sh" init)
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" run_started '{"phase":"0"}'
  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  [ "$(awk 'END{print NR}' "$LOG_FILE")" = "2" ]
  jq -e '.event == "run_header"' < <(sed -n 1p "$LOG_FILE")
  jq -e '.event == "run_started"' < <(sed -n 2p "$LOG_FILE")
}

# ---- Mechanical channel-env gate (review follow-up) ----
# SKILL.md B0a says "abort if OPS_DRY_RUN=1 and OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID
# unset". Prose alone is not enforcement — a misbehaving model can skip B0a.
# runlog.sh init is the mandatory first B0c call; making it fail here closes
# the hole so dry-run can't proceed without the test channel configured.

@test "init fails when OPS_DRY_RUN=1 and dry-run channel env is unset" {
  unset OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID
  run env OPS_DRY_RUN=1 "$SCRIPTS_DIR/runlog.sh" init
  [ "$status" -ne 0 ]
  [[ "$output" == *"OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID"* ]]
}

@test "init fails when OPS_DRY_RUN=1 and dry-run channel env is empty string" {
  run env OPS_DRY_RUN=1 OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID= "$SCRIPTS_DIR/runlog.sh" init
  [ "$status" -ne 0 ]
  [[ "$output" == *"OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID"* ]]
}

@test "init succeeds when OPS_DRY_RUN=1 and dry-run channel env is set" {
  run env OPS_DRY_RUN=1 OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID=C0TEST123 "$SCRIPTS_DIR/runlog.sh" init
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]{6}$ ]]
}

@test "init does NOT require the dry-run channel env when OPS_DRY_RUN is unset (prod path unchanged)" {
  unset OPS_DRY_RUN OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID
  run "$SCRIPTS_DIR/runlog.sh" init
  [ "$status" -eq 0 ]
}

# --- R4-2: refuse second init when OPS_RUN_ID is already set ---------------
#
# openclaw subagents inherit env from their parent. If the main agent exported
# OPS_RUN_ID and then spawned a subagent, the subagent's B0c would run
# `runlog.sh init` again and create a second parallel run_id, splitting the
# truth floor. Fail here rather than letting two runlogs accumulate. SKILL.md
# B0 HARD RULE forbids subagent-spawn; this is its mechanical counterpart.

@test "R4-2: init refuses (exit 4) when OPS_RUN_ID is already set" {
  run --separate-stderr env OPS_RUN_ID=20260423-120000-aaaaaa "$SCRIPTS_DIR/runlog.sh" init
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"OPS_RUN_ID is already set"* ]]
  [[ "$stderr" == *"20260423-120000-aaaaaa"* ]]
  # stderr names the common cause so the agent can self-diagnose.
  [[ "$stderr" == *"subagent"* ]]
}

@test "R4-2: init proceeds normally when OPS_RUN_ID is unset" {
  unset OPS_RUN_ID
  run "$SCRIPTS_DIR/runlog.sh" init
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]{6}$ ]]
}

@test "R4-2: explicit unset in the same invocation bypasses the guard (rare escape hatch)" {
  # A test harness or manual debug flow can still start a fresh run in a shell
  # that had a lingering OPS_RUN_ID — but only by deliberately unsetting first.
  # env -u OPS_RUN_ID drops it for the child process only.
  run env -u OPS_RUN_ID "$SCRIPTS_DIR/runlog.sh" init
  [ "$status" -eq 0 ]
}

@test "R4-2: event (not init) is NOT affected by the OPS_RUN_ID guard" {
  # Events write into an existing run; they don't create new run_ids. Guarding
  # them would break the normal per-event logging pattern where B0c exports
  # OPS_RUN_ID once and every subsequent event call relies on it.
  first_run=$("$SCRIPTS_DIR/runlog.sh" init)
  run env OPS_RUN_ID=20260423-120000-aaaaaa "$SCRIPTS_DIR/runlog.sh" event "$first_run" test_event '{"k":"v"}'
  [ "$status" -eq 0 ]
}

# ---- Per-profile evidence gate (PR #235) ----
# Run 20260501-100843-d27818 emitted 10 verdicts + 5 escalation_posted in 1
# second with 0 per-profile browses. The dispatcher caught the writes (exits
# 5/3/6) but the runlog still recorded bogus "decisions". This gate refuses
# verdict / escalation_posted events at the source when no successful browser
# load for the named profile_id exists in the current run window.

# Helper: write a fake session log with a successful browser toolCall+toolResult
# pair targeting $1 (URL) and $2 (text body). The runlog gate uses
# CV_SESSION_LOG_OVERRIDE to point at this file. Default URL is a Tier-1
# host (musicbrainz.org) and default text mentions Drezar + Yellow
# Submarine + songwriter so the per-profile claim-match gate passes when
# CV_PROFILE_CREDITED_NAME=Drezar etc. is exported.
seed_browser_session() {
  local url="${1:-https://musicbrainz.org/artist/abc}"
  local text="${2:-Drezar — songwriter on Yellow Submarine}"
  local session="$TEST_TMPDIR/agent-session.jsonl"
  jq -n -c --arg url "$url" --arg text "$text" \
    '{message:{content:[{type:"toolCall", id:"tc1", name:"browser", arguments:{url:$url}}]}}' \
    > "$session"
  jq -n -c --arg text "$text" \
    '{message:{role:"toolResult", toolCallId:"tc1", isError:false, content:[{text:$text}]}}' \
    >> "$session"
  echo "$session"
}

# Build a synthetic session log that satisfies the tier1_unreachable bypass
# preconditions: ≥2 distinct Tier-1 browser opens (URL or response text
# contains credited_name or track_title) AND ≥1 web_search call mentioning
# the same. Default credited_name=Drezar, track=Yellow Submarine — match
# the values that other tests pass to CV_PROFILE_*.
seed_bypass_eligible_session() {
  local credited="${1:-Drezar}"
  local track="${2:-Yellow Submarine}"
  local session="$TEST_TMPDIR/agent-session-bypass.jsonl"
  : > "$session"

  # Tier-1 attempt 1: musicbrainz search for the credited name + track
  jq -n -c --arg url "https://musicbrainz.org/search?query=${credited// /+}+${track// /+}&type=recording" \
    '{message:{content:[{type:"toolCall", id:"tc_mb", name:"browser", arguments:{url:$url, action:"open"}}]}}' \
    >> "$session"
  jq -n -c --arg text "Found 0 results for $credited $track. No matches in MusicBrainz." \
    '{message:{role:"toolResult", toolCallId:"tc_mb", isError:false, content:[{text:$text}]}}' \
    >> "$session"

  # Tier-1 attempt 2: apple music search for the credited name + track
  jq -n -c --arg url "https://music.apple.com/us/search?term=${credited// /+}+${track// /+}" \
    '{message:{content:[{type:"toolCall", id:"tc_apple", name:"browser", arguments:{url:$url, action:"open"}}]}}' \
    >> "$session"
  jq -n -c --arg text "No Results for \"$credited $track\". Try a new search." \
    '{message:{role:"toolResult", toolCallId:"tc_apple", isError:false, content:[{text:$text}]}}' \
    >> "$session"

  # Browser-based search fallback (step 1b) — sanctioned alternative to
  # web_search (which is plugin-blocked in CV sessions). Loads a search-
  # engine URL whose ?q= mentions credited_name + track_title.
  q_enc=$(printf '%s %s credit' "$credited" "$track" | jq -sRr @uri)
  jq -n -c --arg url "https://duckduckgo.com/?q=${q_enc}" \
    '{message:{content:[{type:"toolCall", id:"tc_ws", name:"browser", arguments:{url:$url, action:"open"}}]}}' \
    >> "$session"
  jq -n -c '{message:{role:"toolResult", toolCallId:"tc_ws", isError:false, content:[{text:"DuckDuckGo returned 3 results — no credible corroboration"}]}}' \
    >> "$session"

  echo "$session"
}

@test "verdict with profile_id + matching Tier-1 browser load is accepted" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="abc-1234-profile-id"
  SESSION=$(seed_browser_session "https://musicbrainz.org/artist/$PID" "Drezar — songwriter on Yellow Submarine")
  run env \
    CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"LEGITIMATE"}')"
  [ "$status" -eq 0 ]
}

@test "verdict with profile_id but NO browser load is refused (exit 7)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="no-browse-profile-id"
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"
  run env CV_SESSION_LOG_OVERRIDE="$EMPTY" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"LEGITIMATE"}')"
  [ "$status" -eq 7 ]
  # Message is mode-aware after the 2026-05-06 cutover. Browser-mode says
  # "Tier-1 browser snapshot"; api-mode says "evidence source". The label
  # `verdict_without_evidence` is mode-independent — assert on that.
  [[ "$output" == *"verdict_without_evidence"* ]]
  [[ "$output" == *"$PID"* ]]
}

@test "escalation_posted with profile_id but NO browser load is refused (exit 7)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="no-browse-escalation-id"
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"
  run env CV_SESSION_LOG_OVERRIDE="$EMPTY" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" escalation_posted \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, reason:"high risk"}')"
  [ "$status" -eq 7 ]
}

@test "verdict with reason tier1_unreachable BUT empty session log is REFUSED (insufficient effort)" {
  # 2026-05-04 17:44 run lesson: the agent stamped tier1_unreachable on 5
  # profiles with thin/no browser activity and the audit accepted them via
  # bypass parity. The bypass now requires ≥2 distinct Tier-1 browser opens
  # for the profile AND ≥1 web_search call. An empty session log means
  # neither — refuse with exit 7.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="bypass-without-effort-pid"
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"
  run env CV_SESSION_LOG_OVERRIDE="$EMPTY" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"INCONCLUSIVE", reason:"tier1_unreachable: spotify captcha + musicbrainz 503"}')"
  [ "$status" -eq 7 ]
  [[ "$output" == *"tier1_unreachable_insufficient_effort"* ]]
}

@test "verdict with reason tier1_unreachable + 2 Tier-1 attempts + web_search is accepted" {
  # The legitimate path: agent loaded ≥2 Tier-1 hosts (their pages didn't
  # confirm — search returned 0 results, etc.) AND ran web_search (no
  # credible corroboration). Now the bypass is genuine "unreachable" not
  # "give up."
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="bypass-with-effort-pid"
  SESSION=$(seed_bypass_eligible_session "Drezar" "Yellow Submarine")
  run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"INCONCLUSIVE", reason:"tier1_unreachable: musicbrainz 0 results, apple no results, web_search no credible corroboration"}')"
  [ "$status" -eq 0 ]
}

@test "verdict with reason tier1_unreachable + only 1 Tier-1 attempt is REFUSED (single-host give-up)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="single-host-pid"
  # Only one Tier-1 host loaded; no web_search.
  SESSION=$(seed_browser_session "https://music.apple.com/us/search?term=Drezar+Yellow+Submarine" "No Results for Drezar Yellow Submarine. Try a new search.")
  run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"INCONCLUSIVE", reason:"tier1_unreachable: apple no results"}')"
  [ "$status" -eq 7 ]
  [[ "$output" == *"tier1_unreachable_insufficient_effort"* ]]
  [[ "$output" == *"got 1"* ]]
}

@test "verdict with reason tier1_unreachable + 2 Tier-1 attempts but NO web_search is REFUSED" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="no-websearch-pid"
  # Two Tier-1 hosts but no web_search call.
  local session="$TEST_TMPDIR/agent-no-ws.jsonl"
  : > "$session"
  jq -n -c --arg url "https://musicbrainz.org/search?query=Drezar+Yellow+Submarine" \
    '{message:{content:[{type:"toolCall", id:"tc1", name:"browser", arguments:{url:$url}}]}}' \
    >> "$session"
  jq -n -c '{message:{role:"toolResult", toolCallId:"tc1", isError:false, content:[{text:"Found 0 results for Drezar Yellow Submarine"}]}}' \
    >> "$session"
  jq -n -c --arg url "https://music.apple.com/us/search?term=Drezar+Yellow+Submarine" \
    '{message:{content:[{type:"toolCall", id:"tc2", name:"browser", arguments:{url:$url}}]}}' \
    >> "$session"
  jq -n -c '{message:{role:"toolResult", toolCallId:"tc2", isError:false, content:[{text:"No Results for Drezar Yellow Submarine"}]}}' \
    >> "$session"

  run env CV_SESSION_LOG_OVERRIDE="$session" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"INCONCLUSIVE", reason:"tier1_unreachable: mb + apple no results"}')"
  [ "$status" -eq 7 ]
  [[ "$output" == *"tier1_unreachable_insufficient_effort"* ]]
}

@test "verdict WITHOUT profile_id is allowed (legacy events / non-per-profile)" {
  # Backwards compatibility: verdict events that pre-date PR #235 didn't
  # carry profile_id. Don't break them — the gate only fires when the field
  # is present.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"
  run env CV_SESSION_LOG_OVERRIDE="$EMPTY" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    '{"cr_id":"cr_1","verdict":"LEGITIMATE"}'
  [ "$status" -eq 0 ]
}

@test "non-decision events (credit_fetched / run_started) are NOT gated" {
  # Only verdict + escalation_posted + action_attempted are gated. Other events
  # (credit_fetched, run_started, profile_group_fetched) carry profile metadata
  # too but aren't per-profile decisions.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"
  run env CV_SESSION_LOG_OVERRIDE="$EMPTY" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" credit_fetched \
    '{"cr_id":"cr_1","profile_id":"some-pid"}'
  [ "$status" -eq 0 ]
}

@test "CV_DISABLE_VERDICT_GATE=1 bypasses the gate (test escape hatch)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"
  run env CV_DISABLE_VERDICT_GATE=1 CV_SESSION_LOG_OVERRIDE="$EMPTY" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    '{"cr_id":"cr_1","profile_id":"any","verdict":"LEGITIMATE"}'
  [ "$status" -eq 0 ]
}

# ---- Tier-1 + response-text gate semantics (2026-05-04 refactor) ----
# The muso website anchor was dropped: a per-profile load now requires
# (URL host ∈ Tier-1) AND (response text contains credited_name) AND
# (response text contains track_title OR any role token). These tests
# pin the new rule's edges.

@test "URL contains profile_id but not Tier-1 host → not counted as evidence" {
  # Old gate would have accepted this (URL contains PID). New gate requires
  # the URL host to be one of the Tier-1 set — muso.ai is not Tier-1.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="non-tier1-host-pid"
  SESSION=$(seed_browser_session "https://muso.ai/profile/$PID" "Drezar — songwriter on Yellow Submarine")
  run env \
    CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"LEGITIMATE"}')"
  [ "$status" -eq 7 ]
}

@test "Tier-1 URL with credited_name in response but no track or role → not counted" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="name-only-pid"
  SESSION=$(seed_browser_session "https://musicbrainz.org/artist/$PID" "Drezar's profile page")
  run env \
    CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"LEGITIMATE"}')"
  [ "$status" -eq 7 ]
}

@test "Tier-1 URL with credited_name + track_title in response → counted (gate passes)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="name-track-pid"
  SESSION=$(seed_browser_session "https://allmusic.com/album/foo" "Drezar credited on Yellow Submarine — released 2024")
  run env \
    CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"LEGITIMATE"}')"
  [ "$status" -eq 0 ]
}

@test "Tier-1 URL with credited_name + role token (no track_title in text) → counted" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="name-role-pid"
  SESSION=$(seed_browser_session "https://discogs.com/artist/foo" "Drezar — songwriter, producer")
  run env \
    CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Some Other Track" \
    CV_PROFILE_ROLES="songwriter,producer" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"LEGITIMATE"}')"
  [ "$status" -eq 0 ]
}

@test "metadata resolved from profile_group_fetched event when CV_PROFILE_* unset" {
  # The runlog.sh gate looks up credited_name / track_title / role from a
  # prior profile_group_fetched event when the env vars aren't pre-set.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="from-runlog-pid"
  "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" profile_group_fetched \
    "$(jq -nc --arg pid "$PID" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", cr_ids:["cr_1"], count:1}')"
  SESSION=$(seed_browser_session "https://allmusic.com/artist/foo" "Drezar — songwriter on Yellow Submarine")
  run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"LEGITIMATE"}')"
  [ "$status" -eq 0 ]
}

@test "without credited_name (env unset + no profile_group_fetched), gate fails closed" {
  # New rule: cannot prove a claim without the credited person's name.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="no-meta-pid"
  SESSION=$(seed_browser_session "https://musicbrainz.org/artist/foo" "any text")
  run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "$PID" --arg id cr_1 '{cr_id:$id, profile_id:$pid, verdict:"LEGITIMATE"}')"
  [ "$status" -eq 7 ]
}

# ---- action_attempted gate (this PR) ----
# Run 20260501-135646-ecff37 emitted 117 action_attempted events at the same
# second with fabricated evidence_excerpt = "<track> <role>" strings, after
# the subagent pool failed and the agent panic-finalized. action_attempted
# was the open channel through the gate (it was logged BEFORE batch-verify-
# profile.sh, which itself blocked all 500 PUTs). This gate closes that
# bypass at the runlog source.

@test "action_attempted with profile_id + matching Tier-1 browser load is accepted" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="abc-action-attempted-id"
  SESSION=$(seed_browser_session "https://musicbrainz.org/artist/$PID" "Drezar credited as songwriter on Yellow Submarine")
  run env \
    CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" action_attempted \
    "$(jq -nc --arg pid "$PID" '{profile_id:$pid, action:"flag", cr_ids:["cr_1","cr_2"]}')"
  [ "$status" -eq 0 ]
}

@test "action_attempted with profile_id but NO browser load is refused (exit 7)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="no-browse-action-id"
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"
  run env CV_SESSION_LOG_OVERRIDE="$EMPTY" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" action_attempted \
    "$(jq -nc --arg pid "$PID" '{profile_id:$pid, action:"flag", cr_ids:["cr_1"]}')"
  [ "$status" -eq 7 ]
  [[ "$output" == *"acted_without_investigation"* ]]
  [[ "$output" == *"$PID"* ]]
}

@test "action_attempted WITHOUT profile_id is allowed (legacy / batched events)" {
  # Backwards compat: pre-PR action_attempted events that lacked profile_id.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"
  run env CV_SESSION_LOG_OVERRIDE="$EMPTY" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" action_attempted \
    '{"action":"approve","cr_ids":["cr_1"]}'
  [ "$status" -eq 0 ]
}

@test "action_attempted with reason tier1_unreachable BUT empty session is REFUSED" {
  # 2026-05-04 17:44 lesson: bypass label without effort is no longer a free
  # pass. Same contract as verdict — bypass requires ≥2 Tier-1 attempts +
  # ≥1 web_search call mentioning credited_name or track_title.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="captcha-action-id"
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"
  run env CV_SESSION_LOG_OVERRIDE="$EMPTY" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" action_attempted \
    "$(jq -nc --arg pid "$PID" '{profile_id:$pid, action:"escalate", cr_ids:["cr_1"], reason:"tier1_unreachable: 5xx storm"}')"
  [ "$status" -eq 7 ]
  [[ "$output" == *"tier1_unreachable_insufficient_effort"* ]]
}

@test "action_attempted with reason tier1_unreachable + 2 Tier-1 attempts + web_search is accepted" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  PID="bypass-action-with-effort"
  SESSION=$(seed_bypass_eligible_session "Drezar" "Yellow Submarine")
  run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" \
    CV_PROFILE_TRACK_TITLE="Yellow Submarine" \
    CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" action_attempted \
    "$(jq -nc --arg pid "$PID" '{profile_id:$pid, action:"escalate", cr_ids:["cr_1"], reason:"tier1_unreachable: musicbrainz no results, apple no results, web_search no credible corroboration"}')"
  [ "$status" -eq 0 ]
}

@test "cookie-cutter: 3rd byte-identical verdict.reason in same run is refused" {
  # 2026-05-04 fabrication shape: 28 byte-identical reason strings across
  # 28 unrelated credits. Refuse the 3rd identical write regardless of
  # the tier1_unreachable bypass.
  #
  # Setup: session log satisfies the tier1_unreachable bypass preconditions
  # (≥2 Tier-1 attempts + ≥1 web_search) and CV_PROFILE_* envs are exported,
  # so the verdict gate accepts. The cookie-cutter gate then fires on the
  # 3rd byte-identical reason.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  SESSION=$(seed_bypass_eligible_session "Drezar" "Yellow Submarine")
  REASON="tier1_unreachable: musicbrainz 0 results; apple no result; web_search no credible corroboration"
  # First two: accepted (verdict gate passes, threshold not yet reached)
  run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" CV_PROFILE_TRACK_TITLE="Yellow Submarine" CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "p1" --arg r "$REASON" '{profile_id:$pid, cr_id:"cr_1", reason:$r}')"
  [ "$status" -eq 0 ]
  run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" CV_PROFILE_TRACK_TITLE="Yellow Submarine" CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "p2" --arg r "$REASON" '{profile_id:$pid, cr_id:"cr_2", reason:$r}')"
  [ "$status" -eq 0 ]
  # Third should be refused (cookie_cutter_reason)
  run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" CV_PROFILE_TRACK_TITLE="Yellow Submarine" CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "p3" --arg r "$REASON" '{profile_id:$pid, cr_id:"cr_3", reason:$r}')"
  [ "$status" -eq 12 ]
  [[ "$output" == *"cookie_cutter_reason"* ]]
}

@test "cookie-cutter: distinct reasons are not affected by the gate" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  SESSION=$(seed_bypass_eligible_session "Drezar" "Yellow Submarine")
  for n in 1 2 3 4 5; do
    run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
      CV_PROFILE_CREDITED_NAME="Drezar" CV_PROFILE_TRACK_TITLE="Yellow Submarine" CV_PROFILE_ROLES="songwriter" \
      "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
      "$(jq -nc --arg pid "p$n" --arg cr "cr_$n" --arg r "tier1_unreachable: rate-limited at attempt $n; web_search no corroboration" '{profile_id:$pid, cr_id:$cr, reason:$r}')"
    [ "$status" -eq 0 ]
  done
}

@test "cookie-cutter: CV_DISABLE_COOKIE_CUTTER_GATE=1 bypasses the gate" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  # We're isolating the cookie-cutter gate, so disable the verdict gate too
  # via CV_DISABLE_VERDICT_GATE=1 (the empty session would otherwise refuse
  # all events at the verdict gate).
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"
  REASON="tier1_unreachable: identical-bypass-test"
  for n in 1 2 3 4; do
    run env CV_SESSION_LOG_OVERRIDE="$EMPTY" \
      CV_DISABLE_COOKIE_CUTTER_GATE=1 CV_DISABLE_VERDICT_GATE=1 \
      "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
      "$(jq -nc --arg pid "p$n" --arg cr "cr_$n" --arg r "$REASON" '{profile_id:$pid, cr_id:$cr, reason:$r}')"
    [ "$status" -eq 0 ]
  done
}

@test "metadata events (progress, batch_announced) bypass all gates regardless of repeated text" {
  # progress and batch_announced are UX/metadata events — they may legitimately
  # carry similar text and don't carry decisions. Both gates (cookie-cutter,
  # per-profile evidence) only target verdict/escalation_posted/action_attempted,
  # so progress/batch_announced should always be accepted even with no browser
  # load and even when many events share the same payload structure.
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  EMPTY="$TEST_TMPDIR/empty-session.jsonl"
  : > "$EMPTY"

  run env CV_SESSION_LOG_OVERRIDE="$EMPTY" "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" batch_announced \
    '{"queue_depth":13864,"fetch_size":50,"profile_count":9,"parent_msg_ts":"1.234"}'
  [ "$status" -eq 0 ]

  # Many progress events with the SAME message text — must not trigger cookie-cutter
  for n in 1 2 3 4 5 6 7 8 9; do
    run env CV_SESSION_LOG_OVERRIDE="$EMPTY" "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" progress \
      "$(jq -nc --arg pid "p$n" --argjson n "$n" --argjson t 9 '{profile_id:$pid, processed:$n, total:$t, message:"identical tick text"}')"
    [ "$status" -eq 0 ]
  done

  TODAY=$(date -u +%Y-%m-%d)
  LOG_FILE="$OPS_RUNLOG_DIR/$TODAY/$RUN_ID.jsonl"
  [ "$(jq -s '[.[] | select(.event=="progress")] | length' < "$LOG_FILE")" = "9" ]
  [ "$(jq -s '[.[] | select(.event=="batch_announced")] | length' < "$LOG_FILE")" = "1" ]
}

@test "cookie-cutter: gate scoped per event_name (verdict + escalation_posted counted separately)" {
  RUN_ID=$("$SCRIPTS_DIR/runlog.sh" init)
  SESSION=$(seed_bypass_eligible_session "Drezar" "Yellow Submarine")
  REASON="tier1_unreachable: musicbrainz 0 results; apple no result; web_search no credible corroboration"
  # 2 verdicts with this reason — accepted
  for n in 1 2; do
    run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
      CV_PROFILE_CREDITED_NAME="Drezar" CV_PROFILE_TRACK_TITLE="Yellow Submarine" CV_PROFILE_ROLES="songwriter" \
      "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
      "$(jq -nc --arg pid "p$n" --arg cr "cr_$n" --arg r "$REASON" '{profile_id:$pid, cr_id:$cr, reason:$r}')"
    [ "$status" -eq 0 ]
  done
  # 2 escalation_posted with the SAME reason — also accepted (different event)
  for n in 1 2; do
    run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
      CV_PROFILE_CREDITED_NAME="Drezar" CV_PROFILE_TRACK_TITLE="Yellow Submarine" CV_PROFILE_ROLES="songwriter" \
      "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" escalation_posted \
      "$(jq -nc --arg pid "p$n" --arg cr "cr_$n" --arg r "$REASON" '{profile_id:$pid, cr_id:$cr, reason:$r}')"
    [ "$status" -eq 0 ]
  done
  # 3rd verdict — refused
  run env CV_SESSION_LOG_OVERRIDE="$SESSION" \
    CV_PROFILE_CREDITED_NAME="Drezar" CV_PROFILE_TRACK_TITLE="Yellow Submarine" CV_PROFILE_ROLES="songwriter" \
    "$SCRIPTS_DIR/runlog.sh" event "$RUN_ID" verdict \
    "$(jq -nc --arg pid "p3" --arg cr "cr_3" --arg r "$REASON" '{profile_id:$pid, cr_id:$cr, reason:$r}')"
  [ "$status" -eq 12 ]
}
