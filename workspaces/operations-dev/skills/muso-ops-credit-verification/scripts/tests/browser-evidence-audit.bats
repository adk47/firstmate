#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

setup() {
  setup_tmp_env
  export RUN_ID="20260504-080455-6e3532"
  export DAY="${RUN_ID:0:4}-${RUN_ID:4:2}-${RUN_ID:6:2}"
  export RUN_DIR="$OPS_RUNLOG_DIR/$DAY"
  export RUNLOG_FILE="$RUN_DIR/$RUN_ID.jsonl"
  export SESSION_LOG="$TEST_TMPDIR/session.jsonl"
  mkdir -p "$RUN_DIR"
  : > "$RUNLOG_FILE"
  : > "$SESSION_LOG"
}
teardown() { teardown_tmp_env; }

runlog_event() {
  local event="$1" payload="$2"
  jq -c --arg ev "$event" --arg rid "$RUN_ID" --arg ts "2026-05-04T08:05:00Z" \
    '. + {event:$ev, run_id:$rid, ts:$ts}' <<<"$payload" >> "$RUNLOG_FILE"
}

seed_browser_ok() {
  local id="$1" url="$2" text="${3:-snapshot ok}"
  jq -n -c --arg id "$id" --arg url "$url" \
    '{timestamp:"2026-05-04T08:05:10Z", message:{role:"assistant", content:[{type:"toolCall", id:$id, name:"browser", arguments:{url:$url}}]}}' >> "$SESSION_LOG"
  jq -n -c --arg id "$id" --arg text "$text" \
    '{timestamp:"2026-05-04T08:05:11Z", message:{role:"toolResult", toolCallId:$id, isError:false, content:[{type:"text", text:$text}]}}' >> "$SESSION_LOG"
}

# Seed a Tier-1 browser load whose response text proves the claim
# (credited_name + role + track) for a given profile. Used as the
# replacement for the old muso.ai anchor in test fixtures — the new audit
# attributes a Tier-1 load to a profile when the response text contains
# credited_name AND (track_title OR a role token).
seed_tier1_anchor_for() {
  local id="$1" pid="$2" name="${3:-Drezar}" track="${4:-Yellow Submarine}" role="${5:-songwriter}"
  seed_browser_ok "$id" "https://musicbrainz.org/artist/$pid" "$name credited as $role on $track"
}

# Seed a profile_group_fetched event whose claim metadata matches the
# helper above. Most tests want to assert "decision X has anchor" — call
# both this and seed_tier1_anchor_for to set up a covered profile.
seed_profile_group() {
  local pid="$1" name="${2:-Drezar}" track="${3:-Yellow Submarine}" role="${4:-songwriter}"
  shift; shift 2>/dev/null || true
  runlog_event profile_group_fetched "$(jq -nc \
    --arg pid "$pid" --arg name "$name" --arg track "$track" --arg role "$role" \
    '{profile_id:$pid, credited_name:$name, track_title:$track, role:$role, count:1, cr_ids:["cr_1"]}')"
}

@test "passes when every decision profile has a browser profile anchor" {
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event run_started '{"phase":"0"}'
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  seed_profile_group "$pid"
  runlog_event action_attempted "$(jq -nc --arg pid "$pid" '{profile_id:$pid,action:"escalate",cr_ids:["cr_1"]}')"
  seed_tier1_anchor_for c1 "$pid"
  runlog_event run_finished '{"fetched":1,"approved":0,"verification_needed":0,"escalated":1,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true'
  echo "$output" | jq -e '.decision_profile_count == 1 and .browser_anchor_profile_count == 1'
}

@test "May 4 shape: one browsed profile cannot cover 50 synthetic decision profiles" {
  # The agent really investigated 1 profile (legit Tier-1 evidence with
  # claim match) and then synthesized 50 more decisions for unrelated
  # profiles. Audit must catch this: 1 anchor profile, 51 decision
  # profiles, 50 missing.
  runlog_event run_started '{"phase":"0"}'
  legit_pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  seed_profile_group "$legit_pid"
  seed_tier1_anchor_for c1 "$legit_pid"
  # A second Tier-1 load whose text doesn't match any claim — diagnostic
  # noise, doesn't anchor anything.
  seed_browser_ok c2 "https://musicbrainz.org/track/4UibJ9fYMrKtaKb7UbC9s3" "Sign up. No credit card needed."
  runlog_event verdict "$(jq -nc --arg pid "$legit_pid" '{profile_id:$pid, cr_id:"cr_legit", reason:"approve"}')"

  for n in $(seq 1 50); do
    pid=$(printf '00000000-0000-0000-0000-%012d' "$n")
    runlog_event escalation_posted "$(jq -nc --arg pid "$pid" --arg cr "cr_$n" '{profile_id:$pid, cr_id:$cr, reason:"tier1_unreachable"}')"
    runlog_event action_attempted "$(jq -nc --arg pid "$pid" --arg cr "cr_$n" '{profile_id:$pid, action:"escalate", cr_ids:[$cr], reason:"tier1_unreachable"}')"
  done

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"browser evidence audit failed"* ]]
  echo "$output" | head -1 | jq -e '.decision_profile_count == 51'
  echo "$output" | head -1 | jq -e '.browser_anchor_profile_count == 1'
  echo "$output" | head -1 | jq -e '.missing_anchor_profile_count == 50'
}

@test "decision events without profile_id fail closed" {
  runlog_event run_started '{"phase":"0"}'
  runlog_event action_attempted '{"action":"escalate","cr_ids":["cr_1"]}'
  seed_browser_ok c1 "https://muso.ai/profile/36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  echo "$output" | head -1 | jq -e '.decision_events_without_profile_id == 1'
}

@test "run_started timestamp filters stale browser anchors" {
  runlog_event run_started '{"phase":"0","ts":"ignored"}'
  # Override run_started event with a later timestamp in the actual envelope.
  : > "$RUNLOG_FILE"
  jq -n -c --arg rid "$RUN_ID" '{event:"run_started", run_id:$rid, ts:"2026-05-04T08:05:00Z"}' >> "$RUNLOG_FILE"
  runlog_event action_attempted '{"profile_id":"36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0","action":"escalate","cr_ids":["cr_1"]}'

  jq -n -c '{timestamp:"2026-05-04T08:04:00Z", message:{role:"assistant", content:[{type:"toolCall", id:"old", name:"browser", arguments:{url:"https://muso.ai/profile/36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"}}]}}' >> "$SESSION_LOG"
  jq -n -c '{timestamp:"2026-05-04T08:04:01Z", message:{role:"toolResult", toolCallId:"old", isError:false, content:[{type:"text", text:"old"}]}}' >> "$SESSION_LOG"

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  echo "$output" | head -1 | jq -e '.browser_anchor_profile_count == 0'
}

@test "records Tier-1 hosts whose response text matches the profile's claim" {
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event run_started '{"phase":"0"}'
  seed_profile_group "$pid"
  runlog_event verdict "$(jq -nc --arg pid "$pid" '{profile_id:$pid, verdict:"INCONCLUSIVE"}')"
  # Two Tier-1 hosts whose text proves the claim — both should be attributed.
  seed_browser_ok c2 "https://music.apple.com/us/track/abc" "Drezar credited as songwriter on Yellow Submarine"
  seed_browser_ok c3 "https://musicbrainz.org/recording/def" "Drezar — songwriter — Yellow Submarine"

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" "$RUN_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tier1_hosts_by_profile["36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"] == ["music.apple.com","musicbrainz.org"]'
}

@test "May 4 coverage: 11 fetched / 1 decisioned fails closed with all 10 uncovered profiles listed" {
  runlog_event run_started '{"phase":"0"}'
  # Seed 11 profile_group_fetched events (one decisioned, ten silently dropped)
  decisioned_pid="720db540-ef52-4e2c-994d-ebfcef276a92"
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$decisioned_pid" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:1, cr_ids:["cr_d1"]}')"
  for n in $(seq 1 10); do
    pid=$(printf '00000000-0000-0000-0000-%012d' "$n")
    runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$pid" --arg cr "cr_$n" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:1, cr_ids:[$cr]}')"
  done
  runlog_event verdict "$(jq -nc --arg pid "$decisioned_pid" '{profile_id:$pid, cr_id:"cr_d1", reason:"tier1_unreachable"}')"
  runlog_event escalation_posted "$(jq -nc --arg pid "$decisioned_pid" '{profile_id:$pid, cr_id:"cr_d1"}')"
  seed_tier1_anchor_for c1 "$decisioned_pid"

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fetched profile(s) without any decision"* ]]
  echo "$output" | head -1 | jq -e '.fetched_profile_count == 11'
  echo "$output" | head -1 | jq -e '.uncovered_fetched_profile_count == 10'
  echo "$output" | head -1 | jq -e '.ok == false'
}

@test "reconciliation mismatch fails closed when fetched != sum of buckets" {
  runlog_event run_started '{"phase":"0"}'
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$pid" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:1, cr_ids:["cr_1"]}')"
  runlog_event verdict "$(jq -nc --arg pid "$pid" '{profile_id:$pid, cr_id:"cr_1", reason:"tier1_unreachable: rate-limited"}')"
  runlog_event action_attempted "$(jq -nc --arg pid "$pid" '{profile_id:$pid, action:"escalate", cr_ids:["cr_1"]}')"
  runlog_event escalation_posted "$(jq -nc --arg pid "$pid" '{profile_id:$pid, cr_id:"cr_1"}')"
  seed_tier1_anchor_for c1 "$pid"
  # run_finished claims fetched=50 but only escalated 28 — 22 unaccounted
  runlog_event run_finished '{"fetched":50,"approved":0,"verification_needed":0,"escalated":28,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"reconciliation mismatch=22"* ]]
  echo "$output" | head -1 | jq -e '.reconciliation.fetched == 50'
  echo "$output" | head -1 | jq -e '.reconciliation.sum_buckets == 28'
  echo "$output" | head -1 | jq -e '.reconciliation.mismatch == 22'
  echo "$output" | head -1 | jq -e '.ok == false'
}

@test "cookie-cutter reasons fail closed at default threshold (3)" {
  runlog_event run_started '{"phase":"0"}'
  pid="720db540-ef52-4e2c-994d-ebfcef276a92"
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$pid" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:3, cr_ids:["cr_a","cr_b","cr_c"]}')"
  reason="tier1_unreachable: profile anchor returned 404; AllMusic unavailable; Discogs Cloudflare; Apple/Spotify/MusicBrainz did not expose engineer credit context for Rob Christie on Fly Me To The Moon"
  for cr in cr_a cr_b cr_c; do
    runlog_event verdict "$(jq -nc --arg pid "$pid" --arg cr "$cr" --arg r "$reason" '{profile_id:$pid, cr_id:$cr, reason:$r}')"
    runlog_event escalation_posted "$(jq -nc --arg pid "$pid" --arg cr "$cr" '{profile_id:$pid, cr_id:$cr}')"
  done
  seed_tier1_anchor_for c1 "$pid"
  runlog_event run_finished '{"fetched":3,"approved":0,"verification_needed":0,"escalated":3,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cookie-cutter reason group"* ]]
  echo "$output" | head -1 | jq -e '.cookie_cutter_count == 1'
  echo "$output" | head -1 | jq -e '.cookie_cutter_reasons[0].count == 3'
  echo "$output" | head -1 | jq -e '.ok == false'
}

@test "cookie-cutter does NOT trigger at count=2 (legitimate shared rate-limit reasons)" {
  runlog_event run_started '{"phase":"0"}'
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$pid" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:2, cr_ids:["cr_1","cr_2"]}')"
  for cr in cr_1 cr_2; do
    runlog_event verdict "$(jq -nc --arg pid "$pid" --arg cr "$cr" '{profile_id:$pid, cr_id:$cr, reason:"tier1_unreachable: rate-limited"}')"
    runlog_event action_attempted "$(jq -nc --arg pid "$pid" --arg cr "$cr" '{profile_id:$pid, action:"escalate", cr_ids:[$cr]}')"
    runlog_event escalation_posted "$(jq -nc --arg pid "$pid" --arg cr "$cr" '{profile_id:$pid, cr_id:$cr}')"
  done
  seed_tier1_anchor_for c1 "$pid"
  runlog_event run_finished '{"fetched":2,"approved":0,"verification_needed":0,"escalated":2,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cookie_cutter_count == 0'
  echo "$output" | jq -e '.ok == true'
}

@test "all checks pass for a clean honest run" {
  runlog_event run_started '{"phase":"0"}'
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$pid" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:1, cr_ids:["cr_1"]}')"
  runlog_event verdict "$(jq -nc --arg pid "$pid" '{profile_id:$pid, cr_id:"cr_1", reason:"approve: spotify+musicbrainz confirmed engineer credit"}')"
  runlog_event action_attempted "$(jq -nc --arg pid "$pid" '{profile_id:$pid, action:"approve", cr_ids:["cr_1"]}')"
  seed_tier1_anchor_for c1 "$pid"
  seed_browser_ok c2 "https://musicbrainz.org/track/abc" "spotify rendered"
  runlog_event run_finished '{"fetched":1,"approved":1,"verification_needed":0,"escalated":0,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true'
  echo "$output" | jq -e '.fetched_profile_count == 1'
  echo "$output" | jq -e '.uncovered_fetched_profile_count == 0'
  echo "$output" | jq -e '.cookie_cutter_count == 0'
  echo "$output" | jq -e '.reconciliation.mismatch == 0'
}

@test "P1 regression: empty-run path with reconciliation mismatch fails closed" {
  # Forged runlog: run_finished claims fetched=50 / escalated=28, but no
  # profile_group_fetched and no decision events. Old fast path returned
  # ok:true silently. New path must honor runlog_audit.runlog_ok.
  runlog_event run_started '{"phase":"0"}'
  runlog_event run_finished '{"fetched":50,"approved":0,"verification_needed":0,"escalated":28,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"reconciliation mismatch=22"* ]]
  echo "$output" | head -1 | jq -e '.ok == false'
  echo "$output" | head -1 | jq -e '.reconciliation.mismatch == 22'
}

@test "P1 regression: cookie-cutter on action_attempted is caught by audit (matches append-time gate scope)" {
  # Direct-rewrite bypass: 3 byte-identical action_attempted.reason rows
  # with valid profile anchor + clean reconciliation. Old audit only
  # checked verdict.reason, so this passed.
  runlog_event run_started '{"phase":"0"}'
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$pid" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:3, cr_ids:["cr_1","cr_2","cr_3"]}')"
  reason="tier1_unreachable: copy-paste sentence rewritten directly into action_attempted"
  for cr in cr_1 cr_2 cr_3; do
    runlog_event action_attempted "$(jq -nc --arg pid "$pid" --arg cr "$cr" --arg r "$reason" '{profile_id:$pid, action:"escalate", cr_ids:[$cr], reason:$r}')"
  done
  seed_tier1_anchor_for c1 "$pid"
  runlog_event run_finished '{"fetched":3,"approved":0,"verification_needed":0,"escalated":3,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cookie-cutter reason group"* ]]
  echo "$output" | head -1 | jq -e '.cookie_cutter_count == 1'
  echo "$output" | head -1 | jq -e '.cookie_cutter_reasons[0].event == "action_attempted"'
  echo "$output" | head -1 | jq -e '.cookie_cutter_reasons[0].count == 3'
}

@test "P1 regression: cookie-cutter on escalation_posted is caught by audit" {
  runlog_event run_started '{"phase":"0"}'
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$pid" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:3, cr_ids:["cr_1","cr_2","cr_3"]}')"
  reason="tier1_unreachable: identical-via-direct-rewrite-of-escalation"
  for cr in cr_1 cr_2 cr_3; do
    runlog_event escalation_posted "$(jq -nc --arg pid "$pid" --arg cr "$cr" --arg r "$reason" '{profile_id:$pid, cr_id:$cr, reason:$r}')"
  done
  seed_tier1_anchor_for c1 "$pid"
  runlog_event run_finished '{"fetched":3,"approved":0,"verification_needed":0,"escalated":3,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cookie-cutter reason group"* ]]
  echo "$output" | head -1 | jq -e '.cookie_cutter_reasons[0].event == "escalation_posted"'
  echo "$output" | head -1 | jq -e '.cookie_cutter_reasons[0].count == 3'
}

@test "D regression: two run_finished events — audit reads the LAST one (counter-race fix)" {
  # 2026-05-04 run 20260504-124537-3fd64c: compute-run-summary.sh ran twice.
  # First fired before escalation_posted events landed → run_finished{escalated:0}.
  # Second fired after → run_finished{escalated:50}. Audit must pick the
  # latter so reconciliation reflects truth-of-record.
  runlog_event run_started '{"phase":"0"}'
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$pid" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:1, cr_ids:["cr_1"]}')"
  runlog_event verdict "$(jq -nc --arg pid "$pid" '{profile_id:$pid, cr_id:"cr_1", reason:"tier1_unreachable: rate-limited"}')"
  runlog_event escalation_posted "$(jq -nc --arg pid "$pid" '{profile_id:$pid, cr_id:"cr_1"}')"
  seed_tier1_anchor_for c1 "$pid"
  # Premature run_finished — escalations not yet counted
  runlog_event run_finished '{"fetched":1,"approved":0,"verification_needed":0,"escalated":0,"skipped_idempotent":0,"skipped_cap":0}'
  # Re-run after escalations land — corrected count
  runlog_event run_finished '{"fetched":1,"approved":0,"verification_needed":0,"escalated":1,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reconciliation.escalated == 1'
  echo "$output" | jq -e '.reconciliation.mismatch == 0'
  echo "$output" | jq -e '.ok == true'
}

@test "C.4 regression: missing batch_announced fails closed when fetched > 0" {
  # Honest decisions but no announce event = the agent skipped the in-thread
  # 'starting' message. Audit must refuse so post-batch-summary won't post
  # a final summary without the user having seen the start announcement.
  runlog_event run_started '{"phase":"0"}'
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  # NO batch_announced event seeded
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$pid" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:1, cr_ids:["cr_1"]}')"
  runlog_event verdict "$(jq -nc --arg pid "$pid" '{profile_id:$pid, cr_id:"cr_1", reason:"approve: spotify confirmed"}')"
  runlog_event action_attempted "$(jq -nc --arg pid "$pid" '{profile_id:$pid, action:"approve", cr_ids:["cr_1"]}')"
  seed_tier1_anchor_for c1 "$pid"
  runlog_event run_finished '{"fetched":1,"approved":1,"verification_needed":0,"escalated":0,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"announce_missing=true"* ]]
  echo "$output" | head -1 | jq -e '.announce_missing == true'
  echo "$output" | head -1 | jq -e '.announce_count == 0'
  echo "$output" | head -1 | jq -e '.ok == false'
}

@test "C.4 regression: missing batch_announced is OK when fetched == 0 (empty / dry preview)" {
  # Empty run with no fetches does not require announce — preserves the
  # legitimate queue-clear path (B5: queue depth 0, no items).
  runlog_event run_started '{"phase":"0"}'
  runlog_event run_finished '{"fetched":0,"approved":0,"verification_needed":0,"escalated":0,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.announce_missing == false'
  echo "$output" | jq -e '.ok == true'
}

@test "P1 regression: identical reason across event types does NOT collapse to a cookie-cutter group" {
  # 2 verdicts + 2 escalation_posted + 2 action_attempted with the SAME
  # reason should NOT trigger cookie-cutter (each group is at count=2,
  # below threshold=3). This validates the per-event-type grouping.
  runlog_event run_started '{"phase":"0"}'
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  runlog_event profile_group_fetched "$(jq -nc --arg pid "$pid" '{profile_id:$pid, credited_name:"Drezar", track_title:"Yellow Submarine", role:"songwriter", count:2, cr_ids:["cr_1","cr_2"]}')"
  reason="tier1_unreachable: rate-limited"
  for cr in cr_1 cr_2; do
    runlog_event verdict "$(jq -nc --arg pid "$pid" --arg cr "$cr" --arg r "$reason" '{profile_id:$pid, cr_id:$cr, reason:$r}')"
    runlog_event action_attempted "$(jq -nc --arg pid "$pid" --arg cr "$cr" --arg r "$reason" '{profile_id:$pid, action:"escalate", cr_ids:[$cr], reason:$r}')"
    runlog_event escalation_posted "$(jq -nc --arg pid "$pid" --arg cr "$cr" --arg r "$reason" '{profile_id:$pid, cr_id:$cr, reason:$r}')"
  done
  seed_tier1_anchor_for c1 "$pid"
  runlog_event run_finished '{"fetched":2,"approved":0,"verification_needed":0,"escalated":2,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cookie_cutter_count == 0'
  echo "$output" | jq -e '.ok == true'
}

# Helpers for the bypass-tightening tests (2026-05-04 round). The bypass
# parity rule no longer accepts "all decisions stamped tier1_unreachable" on
# its own — a profile only earns the bypass anchor when the session log
# also shows ≥2 distinct Tier-1 attempts (URL or response text mentions
# credited_name or track_title) AND ≥1 web_search call mentioning
# credited_name or track_title.

# Seed a Tier-1 attempt that does NOT confirm the claim. URL query string
# carries credited_name + track_title (so the load is attributed via the
# URL) but the response text deliberately omits both, so the claim-match
# rule fails while the attempt-attribution rule succeeds.
seed_tier1_attempt_for() {
  local id="$1" pid="$2" host="${3:-musicbrainz.org}" name="${4:-Drezar}" track="${5:-Yellow Submarine}"
  local url="https://${host}/search?q=${name// /+}+${track// /+}"
  jq -n -c --arg id "$id" --arg url "$url" \
    '{timestamp:"2026-05-04T08:05:10Z", message:{role:"assistant", content:[{type:"toolCall", id:$id, name:"browser", arguments:{url:$url, action:"open"}}]}}' >> "$SESSION_LOG"
  jq -n -c --arg id "$id" \
    '{timestamp:"2026-05-04T08:05:11Z", message:{role:"toolResult", toolCallId:$id, isError:false, content:[{type:"text", text:"No matching tracks. Refine your search."}]}}' >> "$SESSION_LOG"
}

# Seed a sanctioned search-engine browser load attributed to the profile
# (URL ?q= mentions credited_name + track_title). Used to satisfy the bypass
# precondition. web_search is plugin-blocked in CV; the SKILL routes the
# corroboration step through `browser` to a duckduckgo/bing/google URL.
seed_web_search_for() {
  local id="$1" pid="$2" name="${3:-Drezar}" track="${4:-Yellow Submarine}"
  local url
  url="https://duckduckgo.com/?q=$(printf '%s %s credit' "$name" "$track" | jq -sRr @uri)"
  jq -n -c --arg id "$id" --arg url "$url" \
    '{timestamp:"2026-05-04T08:05:12Z", message:{role:"assistant", content:[{type:"toolCall", id:$id, name:"browser", arguments:{url:$url, action:"open"}}]}}' >> "$SESSION_LOG"
  jq -n -c --arg id "$id" \
    '{timestamp:"2026-05-04T08:05:13Z", message:{role:"toolResult", toolCallId:$id, isError:false, content:[{type:"text", text:"3 results, no credible corroboration"}]}}' >> "$SESSION_LOG"
}

@test "tier1_unreachable bypass: REFUSED when session has no Tier-1 attempts (2026-05-04 17:44 lesson)" {
  # The 2026-05-04 17:44 run shipped 5 profiles all stamped tier1_unreachable
  # with thin browser evidence, and the audit accepted them via the old
  # bypass parity rule. The new rule requires effort.
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event run_started '{"phase":"0"}'
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  seed_profile_group "$pid"
  reason="tier1_unreachable: did not reach two confirming sources in this run"
  runlog_event verdict "$(jq -nc --arg pid "$pid" --arg r "$reason" '{profile_id:$pid, cr_id:"cr_1", reason:$r}')"
  runlog_event action_attempted "$(jq -nc --arg pid "$pid" --arg r "$reason" '{profile_id:$pid, action:"escalate", cr_ids:["cr_1"], reason:$r}')"
  runlog_event run_finished '{"fetched":1,"approved":0,"verification_needed":0,"escalated":1,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"browser evidence audit failed"* ]]
  echo "$output" | head -1 | jq -e '.missing_anchor_profile_count == 1'
  echo "$output" | head -1 | jq -e '.bypass_anchored_profiles | length == 0'
}

@test "tier1_unreachable bypass: ACCEPTED with 2 Tier-1 attempts + web_search" {
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event run_started '{"phase":"0"}'
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  seed_profile_group "$pid"
  reason="tier1_unreachable: musicbrainz 0 results; apple no results; web_search no credible corroboration"
  runlog_event verdict "$(jq -nc --arg pid "$pid" --arg r "$reason" '{profile_id:$pid, cr_id:"cr_1", reason:$r}')"
  runlog_event action_attempted "$(jq -nc --arg pid "$pid" --arg r "$reason" '{profile_id:$pid, action:"escalate", cr_ids:["cr_1"], reason:$r}')"
  seed_tier1_attempt_for tc_mb "$pid" musicbrainz.org
  seed_tier1_attempt_for tc_apple "$pid" music.apple.com
  seed_web_search_for tc_ws "$pid"
  runlog_event run_finished '{"fetched":1,"approved":0,"verification_needed":0,"escalated":1,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true'
  echo "$output" | jq -e '.bypass_anchored_profiles | length == 1'
  echo "$output" | jq -e '.tier1_attempts_by_profile["36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"] >= 2'
  echo "$output" | jq -e '.web_searches_by_profile["36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"] >= 1'
}

@test "tier1_unreachable bypass: REFUSED with 2 Tier-1 attempts but NO web_search (SKILL.md step 1b skipped)" {
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event run_started '{"phase":"0"}'
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  seed_profile_group "$pid"
  reason="tier1_unreachable: mb 0 results, apple no results"
  runlog_event verdict "$(jq -nc --arg pid "$pid" --arg r "$reason" '{profile_id:$pid, cr_id:"cr_1", reason:$r}')"
  runlog_event action_attempted "$(jq -nc --arg pid "$pid" --arg r "$reason" '{profile_id:$pid, action:"escalate", cr_ids:["cr_1"], reason:$r}')"
  seed_tier1_attempt_for tc_mb "$pid" musicbrainz.org
  seed_tier1_attempt_for tc_apple "$pid" music.apple.com
  # NO web_search call
  runlog_event run_finished '{"fetched":1,"approved":0,"verification_needed":0,"escalated":1,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  echo "$output" | head -1 | jq -e '.missing_anchor_profile_count == 1'
  echo "$output" | head -1 | jq -e '.tier1_attempts_by_profile["36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"] >= 2'
  echo "$output" | head -1 | jq -e '(.web_searches_by_profile["36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"] // 0) == 0'
}

@test "tier1_unreachable bypass: REFUSED with only 1 Tier-1 attempt + web_search (single-host give-up)" {
  pid="36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"
  runlog_event run_started '{"phase":"0"}'
  runlog_event batch_announced '{"queue_depth":100,"fetch_size":1,"profile_count":1,"parent_msg_ts":"1.1"}'
  seed_profile_group "$pid"
  reason="tier1_unreachable: only mb checked, web_search no corroboration"
  runlog_event verdict "$(jq -nc --arg pid "$pid" --arg r "$reason" '{profile_id:$pid, cr_id:"cr_1", reason:$r}')"
  runlog_event action_attempted "$(jq -nc --arg pid "$pid" --arg r "$reason" '{profile_id:$pid, action:"escalate", cr_ids:["cr_1"], reason:$r}')"
  seed_tier1_attempt_for tc_mb "$pid" musicbrainz.org
  seed_web_search_for tc_ws "$pid"
  runlog_event run_finished '{"fetched":1,"approved":0,"verification_needed":0,"escalated":1,"skipped_idempotent":0,"skipped_cap":0}'

  run env CV_SESSION_LOG_OVERRIDE="$SESSION_LOG" "$SCRIPTS_DIR/browser-evidence-audit.sh" --assert "$RUN_ID"
  [ "$status" -eq 1 ]
  echo "$output" | head -1 | jq -e '.missing_anchor_profile_count == 1'
  echo "$output" | head -1 | jq -e '(.tier1_attempts_by_profile["36b8d0e3-fc80-46a9-a19a-a74c0ebefbd0"] // 0) == 1'
}
