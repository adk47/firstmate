#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for render-slack-summary.sh — the authoritative renderer for the
# batch Slack summary. Replaces the 2026-04-23 failure mode where the
# agent composed free-form prose ("174 APPROVE-ELIGIBLE", "Tom Baker",
# etc.) that didn't match the truth floor.

load helpers

setup() {
    setup_tmp_env
    export RUN_ID="20260423-090219-testing"
    export PARENT_MSG_TS="1776935806.440779"
    local day="${RUN_ID:0:8}"
    RUNLOG_DIR="$OPS_RUNLOG_DIR/${day:0:4}-${day:4:2}-${day:6:2}"
    mkdir -p "$RUNLOG_DIR"
    export RUNLOG_FILE="$RUNLOG_DIR/${RUN_ID}.jsonl"
    : > "$RUNLOG_FILE"
    export CV_RESULTS_PATH="$TEST_TMPDIR/credit-results.jsonl"
    : > "$CV_RESULTS_PATH"
}
teardown() { teardown_tmp_env; }

seed_results() {
    # args: intended_status outcome request_ids_json
    local status="$1" outcome="$2" ids="$3"
    jq -n -c --arg s "$status" --arg o "$outcome" --argjson ids "$ids" --arg rid "$RUN_ID" \
        '{ts:"2026-04-23T09:19:00Z", run_id:$rid, method:"PUT", path:"/admin/credit-requests",
          request_ids:$ids, intended_status:$s, outcome:$o,
          http_status:(if $o == "ok" or $o == "dry_run_intercept" then 200 else null end),
          error:null, requester:null}' >> "$CV_RESULTS_PATH"
}

seed_run_finished() {
    # args: dryRun silent_failure approved verification_needed rejected_by_gate
    #       [http_err_uvn] [rejected_pre_flight] [transport_err_approved] [transport_err_uvn]
    local dry="$1" silent="$2" appr="$3" vn="$4" rbg="$5"
    local http_err_uvn="${6:-0}" rpf="${7:-0}"
    local transport_err_approved="${8:-0}" transport_err_uvn="${9:-0}"
    jq -n -c --arg rid "$RUN_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson dry "$dry" --argjson silent "$silent" \
        --argjson appr "$appr" --argjson vn "$vn" --argjson rbg "$rbg" \
        --argjson eu "$http_err_uvn" --argjson rpf "$rpf" \
        --argjson eta "$transport_err_approved" --argjson etu "$transport_err_uvn" \
    '{event:"run_finished", run_id:$rid, ts:$ts,
      fetched:500, approved:$appr, verification_needed:$vn, escalated:0,
      skipped_idempotent:0, skipped_cap:0, errors:0,
      preflight_ok:true, hollow:false, ungrounded:false,
      silent_failure_detected:$silent, dryRun:$dry,
      reconciliation:{source:"results_jsonl",
                      approved_attempted:($rbg + $rpf + $appr), approved_landed:$appr,
                      approved_rejected_by_gate:$rbg,
                      approved_rejected_pre_flight:$rpf,
                      approved_http_error:0,
                      approved_transport_error:$eta,
                      verification_needed_attempted:($vn + $eu), verification_needed_landed:$vn,
                      verification_needed_http_error:$eu,
                      verification_needed_transport_error:$etu}}' >> "$RUNLOG_FILE"
}

# --- Error / missing input ---

@test "missing RUN_ID arg → exit non-zero" {
    run "$SCRIPTS_DIR/render-slack-summary.sh"
    [ "$status" -ne 0 ]
}

@test "missing OPS_RUNLOG_DIR → exit 2" {
    unset OPS_RUNLOG_DIR
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 2 ]
}

@test "missing runlog file → exit 5" {
    rm -f "$RUNLOG_FILE"
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 5 ]
}

@test "missing run_finished event → exit 6 (compute-run-summary must run first)" {
    # Runlog exists but has no run_finished event.
    jq -n -c '{event:"run_header", ts:"2026-04-23T09:00:00Z", dryRun:true}' > "$RUNLOG_FILE"
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 6 ]
}

# --- Happy path ---

@test "happy dry-run: parent has [DRY RUN] prefix + authoritative counts" {
    seed_run_finished true false 145 167 0 0
    seed_results approved dry_run_intercept '["cr_1","cr_2"]'
    seed_results user_verification_needed dry_run_intercept '["cr_3","cr_4","cr_5"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY RUN] Credit batch complete"* ]]
    [[ "$output" == *"Approved: 145"* ]]
    [[ "$output" == *"verification_needed: 167"* ]]
    [[ "$output" == *"Fetched: 500"* ]]
    [[ "$output" == *"===THREAD==="* ]]
    [[ "$output" == *"Run ID: $RUN_ID"* ]]
}

@test "prod run (dryRun=false): no [DRY RUN] prefix" {
    seed_run_finished false false 100 50 0 0
    seed_results approved ok '["cr_1"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Credit batch complete"* ]]
    [[ "$output" != *"[DRY RUN]"* ]]
}

# --- Core invariant: DISCREPANCY banner on silent failure ---

@test "silent_failure → DISCREPANCY banner prepended to parent" {
    seed_run_finished true true 0 167 14 0
    seed_results approved rejected_by_gate '["cr_a","cr_b","cr_c","cr_d","cr_e","cr_f","cr_g","cr_h","cr_i","cr_j","cr_k","cr_l","cr_m","cr_n"]'
    seed_results user_verification_needed dry_run_intercept '["cr_1","cr_2","cr_3"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DISCREPANCY DETECTED"* ]]
    [[ "$output" == *"14 approve(s) rejected by gate"* ]]
    [[ "$output" == *"Approved: 0"* ]]
}

@test "partial silent (some landed, some blocked): banner on parent, no DISCREPANCY" {
    # Not technically silent_failure (some approves landed), but surface the
    # rejected count so Slack readers see it. The renderer's partial-silent
    # branch lumps pre-flight + gate into a single "blocked" total; the
    # split-out wording is reserved for the full DISCREPANCY path.
    seed_run_finished true false 100 50 5 0
    seed_results approved ok '["cr_1","cr_2","cr_3","cr_4","cr_5"]'
    seed_results approved rejected_by_gate '["cr_x","cr_y","cr_z","cr_p","cr_q"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" != *"DISCREPANCY DETECTED"* ]]
    [[ "$output" == *"5 approve(s) blocked (pre-flight + gate)"* ]]
}

# --- Thread reply content ---

@test "thread: lists UVN credit IDs only — NO profile names (R2-5 invariant)" {
    # Agent's 2026-04-23 prose had "Tom Baker mastering engineer", "Eric Padget",
    # etc. These don't exist in results.jsonl. Renderer MUST NOT emit profile
    # names — it can only render what the truth floor knows.
    seed_run_finished true false 0 3 0 0
    seed_results user_verification_needed dry_run_intercept '["abc-1","def-2","ghi-3"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    # UVN listed as credit IDs only.
    [[ "$output" == *"verification_needed (3 credits)"* ]]
    [[ "$output" == *"abc-1"* ]]
    [[ "$output" == *"def-2"* ]]
    [[ "$output" == *"ghi-3"* ]]
    # NO profile-name prose like "Tom Baker" / "Eric Padget" / "43 profiles".
    [[ "$output" != *"Tom Baker"* ]]
    [[ "$output" != *"43 profiles"* ]]
}

@test "thread: caps long lists at 25 credits with '+N more' suffix" {
    seed_run_finished true false 0 30 0 0
    local ids_json
    ids_json=$(jq -n -c '[range(0;30) | "cr_" + tostring]')
    seed_results user_verification_needed dry_run_intercept "$ids_json"
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    # First 25 should appear; remaining 5 rolled into a summary line.
    [[ "$output" == *"verification_needed (30 credits)"* ]]
    [[ "$output" == *"+5 more"* ]]
}

@test "thread: config-mismatch credits surfaced under R2-1 section" {
    # Simulate the R2-1 guard firing — an exec shell missed OPS_DRY_RUN and
    # the muso-admin-api.sh wrote outcome=dry_run_config_mismatch.
    seed_run_finished true false 0 5 0 0
    seed_results user_verification_needed dry_run_intercept '["cr_a","cr_b","cr_c","cr_d","cr_e"]'
    seed_results user_verification_needed dry_run_config_mismatch '["cr_leak_1","cr_leak_2"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Config-mismatch refusals"* ]]
    [[ "$output" == *"cr_leak_1"* ]]
}

@test "thread: http_error UVN credits listed under 'UVN flag HTTP errors'" {
    # The 2026-04-23 run had 12 UVN 404s. Surface them separately so a reader
    # knows these credits did NOT get flagged (network/route issue).
    seed_run_finished true false 0 3 0 2
    seed_results user_verification_needed dry_run_intercept '["cr_ok1","cr_ok2","cr_ok3"]'
    seed_results user_verification_needed http_error '["cr_err1","cr_err2"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"UVN flag HTTP errors"* ]]
    [[ "$output" == *"cr_err1"* ]]
    # Parent also warns about http_error count.
    [[ "$output" == *"2 admin-API call(s) errored"* ]]
}

@test "thread: transport failures are separate from backend HTTP errors" {
    seed_run_finished false true 0 0 0 0 0 1 2
    seed_results approved transport_error '["cr_dns_approve"]'
    seed_results user_verification_needed transport_error '["cr_dns_uvn_1","cr_dns_uvn_2"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 admin-API write(s): no backend refusal was observed; delivery remains unconfirmed after the safe retry policy"* ]]
    [[ "$output" == *"Transport failures — delivery unconfirmed for 3 credit(s)"* ]]
    [[ "$output" == *"Reconcile current credit state before retrying"* ]]
    [[ "$output" != *"did NOT land"* ]]
    [[ "$output" != *"backend did not refuse"* ]]
    [[ "$output" == *"cr_dns_approve"* ]]
    [[ "$output" == *"cr_dns_uvn_1"* ]]
    [[ "$output" != *"UVN flag HTTP errors"* ]]
}

@test "thread: empty results.jsonl → placeholder line, never empty body" {
    # Slack's message tool rejects empty text. Renderer must always emit
    # something usable.
    seed_run_finished true false 0 0 0 0
    : > "$CV_RESULTS_PATH"
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"===THREAD==="* ]]
    # Thread section exists and has at least a placeholder.
    thread_part=$(echo "$output" | awk '/^===THREAD===$/{flag=1; next} flag')
    [[ -n "$thread_part" ]]
}

@test "thread: missing results.jsonl entirely → placeholder '(No results.jsonl file)'" {
    seed_run_finished true false 0 0 0 0
    rm -f "$CV_RESULTS_PATH"
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No results.jsonl file"* ]]
}

# --- Split safety ---

@test "output splits cleanly on '===THREAD===' sentinel" {
    seed_run_finished true false 0 1 0 0
    seed_results user_verification_needed dry_run_intercept '["cr_1"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    # Exactly one sentinel line.
    [ "$(echo "$output" | grep -c '^===THREAD===$')" -eq 1 ]
    # Parent (above sentinel) and thread (below) both non-empty.
    local parent_part thread_part
    parent_part=$(echo "$output" | awk '/^===THREAD===$/{exit} {print}')
    thread_part=$(echo "$output" | awk '/^===THREAD===$/{flag=1; next} flag')
    [[ -n "$parent_part" ]]
    [[ -n "$thread_part" ]]
}

# --- R3-final: rejected_pre_flight surfaces in parent + thread ---------------

@test "pre_flight-only silent failure: parent banner names pre-flight refusal" {
    # R3's core failure shape: agent skipped per-profile evidence, dispatcher
    # refused every approve locally, admin API never called. Banner should
    # name pre-flight rather than gate.
    seed_run_finished true true 0 167 0 0 102
    seed_results approved rejected_pre_flight "$(jq -nc '[range(0;102) | "cr_" + tostring]')"
    seed_results user_verification_needed dry_run_intercept "$(jq -nc '[range(0;167) | "uvn_" + tostring]')"
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DISCREPANCY DETECTED"* ]]
    [[ "$output" == *"102 approve(s) refused at per-profile pre-flight"* ]]
    [[ "$output" == *"Approved: 0"* ]]
}

@test "pre_flight + gate mixed: banner names both with counts" {
    # Rare but possible: some profiles pre-flight refused, some gate rejected.
    seed_run_finished true true 0 0 5 0 10
    seed_results approved rejected_pre_flight "$(jq -nc '[range(0;10) | "pf_" + tostring]')"
    seed_results approved rejected_by_gate "$(jq -nc '[range(0;5) | "gt_" + tostring]')"
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DISCREPANCY DETECTED"* ]]
    [[ "$output" == *"10 pre-flight refused, 5 rejected by gate"* ]]
}

@test "partial pre_flight (some landed, some refused): banner, no DISCREPANCY" {
    # Not silent failure — some approves did land — but surface the refused count.
    seed_run_finished true false 50 0 0 0 10
    seed_results approved ok "$(jq -nc '[range(0;50) | "ok_" + tostring]')"
    seed_results approved rejected_pre_flight "$(jq -nc '[range(0;10) | "pf_" + tostring]')"
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" != *"DISCREPANCY DETECTED"* ]]
    [[ "$output" == *"10 approve(s) blocked"* ]]
}

@test "thread: pre-flight refusals listed under distinct section (not rejected-by-gate)" {
    seed_run_finished true true 0 0 0 0 3
    seed_results approved rejected_pre_flight '["cr_pf_1","cr_pf_2","cr_pf_3"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pre-flight refused"* ]]
    [[ "$output" == *"3 approve(s) blocked (per-profile evidence missing)"* ]]
    [[ "$output" == *"cr_pf_1"* ]]
    [[ "$output" == *"cr_pf_2"* ]]
    [[ "$output" == *"cr_pf_3"* ]]
    # Must NOT mislabel as gate rejection.
    [[ "$output" != *"Rejected by gate"* ]]
}

@test "thread: pre-flight and gate sections appear separately when both present" {
    seed_run_finished true true 0 0 2 0 3
    seed_results approved rejected_pre_flight '["cr_pf_1","cr_pf_2","cr_pf_3"]'
    seed_results approved rejected_by_gate '["cr_gt_1","cr_gt_2"]'
    run "$SCRIPTS_DIR/render-slack-summary.sh" "$RUN_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pre-flight refused"* ]]
    [[ "$output" == *"Rejected by gate"* ]]
    [[ "$output" == *"cr_pf_1"* ]]
    [[ "$output" == *"cr_gt_1"* ]]
}
