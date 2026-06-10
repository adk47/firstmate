#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# Tests for score-fraud-signals.sh — the multi-factor PROFILE-LEVEL fraud
# detector that runs AFTER score-backend-signals.sh and BEFORE
# verdict-engine.sh in the ops BATCH pipeline (Caroline / customer-facing is
# OUT OF SCOPE).
#
# Contract under test (see fraud-detection-spec.md and the script header):
#   * CV_FRAUD_MODE=off      → byte-identical pass-through, no _fraud, no
#                              signal_fraud, no Trino call.
#   * CV_FRAUD_MODE=shadow   → every credit gets a _fraud annotation; existing
#                              _signal.bucket UNCHANGED (a signal_approve stays
#                              signal_approve); a top-level signal_fraud array
#                              lists COPIES of over-threshold credits with
#                              _fraud.orig_bucket; counts.signal_approve
#                              unchanged.
#   * CV_FRAUD_MODE=enforce  → over-threshold credits move into signal_fraud,
#                              _signal.bucket="signal_fraud", _signal.reason set
#                              to the fraud reason string, the source array
#                              (e.g. signal_approve) SHRINKS — the auto-approve
#                              downgrade safety property.
#   * Missing CV_FRAUD_RAW_BATCH ⇒ fail-soft pass-through (verdicts unchanged).
#   * Trino helper failure ⇒ muso_only factor unavailable (weight 0), the batch
#     still produces output and exits 0, the OTHER factors still fire.
#
# Stubbing strategy (mirrors profile-audit.bats / render-dry-run-summary.bats):
#   * setup_tmp_env PATH-shadows openclaw (the scorer never calls it, but the
#     suite must never hit prod Slack; defense in depth).
#   * The single external dependency is the Trino lookup. score-fraud-signals.sh
#     invokes scripts/lib/fraud-muso-only-lookup.sh, which resolves the trino
#     wrapper from env TRINO_QUERY_SH. We stub TRINO_QUERY_SH with a fake bash
#     that either emits the saved-query CSV shape ("<uuid>","<pct>") or exits 1
#     to exercise the fail-soft path. No network, no kubectl.
#
# Fixtures (fixtures/fraud/): a raw batch + the matching scored-bucket JSON for
# four named profiles drawn from the real fraud corpus:
#   * Ming Vauz   (creditCount=34, 11 roles incl. many non-creative, spclient
#                  source) → role_inflation + source_quality + establishment.
#                  With a muso-only hit it crosses threshold → the enforce
#                  downgrade case. Backend-bucketed signal_approve.
#   * Roberto Jr  (creditCount=1365, popularity=80, spclient source) →
#                  source_quality fires; establishment does NOT (well over the
#                  Tier-0 floors). Backend signal_approve.
#   * Legit       (creditCount=540, popularity=75, industry source, creative
#                  roles, no risk signals) → NO factors fire. Backend
#                  signal_approve; must stay approve in every mode.
#   * Javon       (creditCount=12, popularity=18, Editorial-only,
#                  reject_high_velocity_profile=1) → role_inflation +
#                  establishment + velocity (the "Javon pattern" non-musical
#                  role velocity scam). Backend signal_review.

SCORER="$SCRIPTS_DIR/lobster-mvp/score-fraud-signals.sh"
FIX="$BATS_TEST_DIRNAME/fixtures/fraud"
RAW="$FIX/raw.json"
SCORED="$FIX/scored.json"

MING="11111111-1111-1111-1111-111111111111"

setup() {
  setup_tmp_env
  [[ -f "$SCORER" ]] || { echo "SCORER missing: $SCORER" >&2; return 1; }
  [[ -f "$RAW" ]] || { echo "RAW fixture missing: $RAW" >&2; return 1; }
  [[ -f "$SCORED" ]] || { echo "SCORED fixture missing: $SCORED" >&2; return 1; }

  # Trino stub: emits the saved-query CSV shape for Ming with a muso-only pct
  # over the 50% firing band. cat>/dev/null drains the SQL on stdin.
  export TRINO_OK="$TEST_TMPDIR/trino-ok.sh"
  cat > "$TRINO_OK" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf '"%s","80.0"\n' "$MING"
exit 0
STUB
  chmod +x "$TRINO_OK"

  # Trino stub that fails (exits 1) — exercises the fail-soft muso_only path.
  export TRINO_FAIL="$TEST_TMPDIR/trino-fail.sh"
  cat > "$TRINO_FAIL" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "trino exploded" >&2
exit 1
STUB
  chmod +x "$TRINO_FAIL"
}
teardown() { teardown_tmp_env; }

# Helper: run the scorer with a given mode/raw/trino, capturing stdout in $output.
# Usage: run_scorer <mode> <raw_path|-> <trino_sh|->
run_scorer() {
  local mode="$1" raw="$2" trino="$3"
  local -a env_args=("CV_FRAUD_MODE=$mode")
  [[ "$raw" != "-" ]] && env_args+=("CV_FRAUD_RAW_BATCH=$raw")
  [[ "$trino" != "-" ]] && env_args+=("TRINO_QUERY_SH=$trino")
  run --separate-stderr env "${env_args[@]}" bash -c "'$SCORER' < '$SCORED'"
}

# ───────────────────────── off ─────────────────────────

@test "off: byte-identical pass-through (no _fraud, no signal_fraud, no Trino)" {
  # A poisoned Trino stub would error loudly if off ever called it.
  POISON="$TEST_TMPDIR/trino-poison.sh"
  cat > "$POISON" <<'STUB'
#!/usr/bin/env bash
echo "OFF MODE MUST NOT CALL TRINO" >&2
exit 1
STUB
  chmod +x "$POISON"

  run --separate-stderr env CV_FRAUD_MODE=off CV_FRAUD_RAW_BATCH="$RAW" \
    TRINO_QUERY_SH="$POISON" bash -c "'$SCORER' < '$SCORED'"
  [ "$status" -eq 0 ]
  # Byte-for-byte identical to the input fixture.
  printf '%s' "$output" > "$TEST_TMPDIR/off-out"
  # bats strips a single trailing newline from $output; compare canonical JSON
  # instead, then assert structurally that nothing was added.
  run jq -S . "$SCORED"
  expected="$output"
  run --separate-stderr env CV_FRAUD_MODE=off CV_FRAUD_RAW_BATCH="$RAW" \
    TRINO_QUERY_SH="$POISON" bash -c "'$SCORER' < '$SCORED' | jq -S ."
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  # No fraud fields anywhere.
  run --separate-stderr env CV_FRAUD_MODE=off CV_FRAUD_RAW_BATCH="$RAW" \
    TRINO_QUERY_SH="$POISON" bash -c "'$SCORER' < '$SCORED' | jq -e 'has(\"signal_fraud\")'"
  [ "$status" -ne 0 ]
  run --separate-stderr env CV_FRAUD_MODE=off CV_FRAUD_RAW_BATCH="$RAW" \
    TRINO_QUERY_SH="$POISON" bash -c "'$SCORER' < '$SCORED' | jq -e '.signal_approve[0]|has(\"_fraud\")'"
  [ "$status" -ne 0 ]
}

@test "off: exact byte identity via cmp against the input fixture" {
  env CV_FRAUD_MODE=off bash -c "'$SCORER' < '$SCORED'" > "$TEST_TMPDIR/off-bytes" 2>/dev/null
  run cmp -s "$TEST_TMPDIR/off-bytes" "$SCORED"
  [ "$status" -eq 0 ]
}

@test "off: unknown CV_FRAUD_MODE warns and falls back to pass-through" {
  run --separate-stderr env CV_FRAUD_MODE=bogus CV_FRAUD_RAW_BATCH="$RAW" \
    bash -c "'$SCORER' < '$SCORED'"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"unknown CV_FRAUD_MODE"* ]]
  # Still no fraud annotations.
  run --separate-stderr env CV_FRAUD_MODE=bogus CV_FRAUD_RAW_BATCH="$RAW" \
    bash -c "'$SCORER' < '$SCORED' | jq -e 'has(\"signal_fraud\")'"
  [ "$status" -ne 0 ]
}

# ───────────────────────── shadow ─────────────────────────

@test "shadow: annotates _fraud but _signal.bucket is UNCHANGED (signal_approve stays approve)" {
  run_scorer shadow "$RAW" "$TRINO_OK"
  [ "$status" -eq 0 ]
  # Ming was signal_approve and is over threshold here, but shadow must NOT
  # move it — its bucket stays signal_approve.
  ming_bucket=$(printf '%s' "$output" | jq -r --arg id cr-ming '.signal_approve[]|select(.cr_id==$id)._signal.bucket')
  [ "$ming_bucket" = "signal_approve" ]
  # It carries a _fraud annotation.
  ming_has=$(printf '%s' "$output" | jq -r --arg id cr-ming '.signal_approve[]|select(.cr_id==$id)|has("_fraud")')
  [ "$ming_has" = "true" ]
  # counts.signal_approve is unchanged (still 3).
  [ "$(printf '%s' "$output" | jq -r '.counts.signal_approve')" = "3" ]
  [ "$(printf '%s' "$output" | jq -r '.signal_approve|length')" = "3" ]
}

@test "shadow: signal_fraud holds COPIES of over-threshold credits with orig_bucket" {
  run_scorer shadow "$RAW" "$TRINO_OK"
  [ "$status" -eq 0 ]
  # Exactly one over-threshold credit in this fixture: Ming.
  [ "$(printf '%s' "$output" | jq -r '.signal_fraud|length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.signal_fraud[0].cr_id')" = "cr-ming" ]
  [ "$(printf '%s' "$output" | jq -r '.signal_fraud[0]._fraud.orig_bucket')" = "signal_approve" ]
  [ "$(printf '%s' "$output" | jq -r '.counts.signal_fraud')" = "1" ]
}

# ───────────────────────── enforce ─────────────────────────

@test "enforce: a fraudulent profile's signal_approve credit is DOWNGRADED to signal_fraud (safety property)" {
  run_scorer enforce "$RAW" "$TRINO_OK"
  [ "$status" -eq 0 ]
  # Ming leaves signal_approve entirely...
  in_approve=$(printf '%s' "$output" | jq -r --arg id cr-ming '[.signal_approve[]|select(.cr_id==$id)]|length')
  [ "$in_approve" = "0" ]
  # ...and lands in signal_fraud with the bucket flipped.
  ming_bucket=$(printf '%s' "$output" | jq -r --arg id cr-ming '.signal_fraud[]|select(.cr_id==$id)._signal.bucket')
  [ "$ming_bucket" = "signal_fraud" ]
  orig=$(printf '%s' "$output" | jq -r --arg id cr-ming '.signal_fraud[]|select(.cr_id==$id)._fraud.orig_bucket')
  [ "$orig" = "signal_approve" ]
  # signal_approve SHRANK from 3 to 2, counters track it.
  [ "$(printf '%s' "$output" | jq -r '.signal_approve|length')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.counts.signal_approve')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.counts.signal_fraud')" = "1" ]
  # The downgraded credit carries the fraud reason on _signal.reason for the
  # audit trail / Slack.
  reason=$(printf '%s' "$output" | jq -r --arg id cr-ming '.signal_fraud[]|select(.cr_id==$id)._signal.reason')
  [[ "$reason" == fraud:* ]]
}

@test "enforce: clean (legit) signal_approve credit is NEVER downgraded" {
  run_scorer enforce "$RAW" "$TRINO_OK"
  [ "$status" -eq 0 ]
  # Legit fires zero factors → stays in signal_approve, no fraud bucket.
  legit_bucket=$(printf '%s' "$output" | jq -r --arg id cr-legit '.signal_approve[]|select(.cr_id==$id)._signal.bucket')
  [ "$legit_bucket" = "signal_approve" ]
  over=$(printf '%s' "$output" | jq -r --arg id cr-legit '.signal_approve[]|select(.cr_id==$id)._fraud.over')
  [ "$over" = "false" ]
  fired=$(printf '%s' "$output" | jq -r --arg id cr-legit '.signal_approve[]|select(.cr_id==$id)._fraud.fired|length')
  [ "$fired" = "0" ]
}

# ───────────────────────── named-fixture factor coverage ─────────────────────────

@test "Ming Vauz: role_inflation + establishment fire (creditCount=34, 11 roles/track)" {
  # Use the failing-Trino path so the assertion is independent of the muso
  # factor — these two factors must fire on the raw profile shape alone.
  run_scorer shadow "$RAW" "$TRINO_FAIL"
  [ "$status" -eq 0 ]
  fired=$(printf '%s' "$output" | jq -c --arg id cr-ming '.signal_approve[]|select(.cr_id==$id)._fraud.fired')
  [[ "$fired" == *'"role_inflation"'* ]]
  [[ "$fired" == *'"establishment"'* ]]
}

@test "Roberto Junior: source_quality fires (spclient source) but establishment does NOT (cc=1365,pop=80)" {
  run_scorer shadow "$RAW" "$TRINO_FAIL"
  [ "$status" -eq 0 ]
  fired=$(printf '%s' "$output" | jq -c --arg id cr-roberto '.signal_approve[]|select(.cr_id==$id)._fraud.fired')
  [[ "$fired" == *'"source_quality"'* ]]
  [[ "$fired" != *'"establishment"'* ]]
}

@test "legit profile: NO fraud factors fire (high creditCount, industry source, creative roles)" {
  run_scorer shadow "$RAW" "$TRINO_FAIL"
  [ "$status" -eq 0 ]
  fired=$(printf '%s' "$output" | jq -r --arg id cr-legit '.signal_approve[]|select(.cr_id==$id)._fraud.fired|length')
  [ "$fired" = "0" ]
  over=$(printf '%s' "$output" | jq -r --arg id cr-legit '.signal_approve[]|select(.cr_id==$id)._fraud.over')
  [ "$over" = "false" ]
}

@test "Javon pattern: role_inflation + establishment + velocity fire (Editorial + high-velocity reject)" {
  run_scorer shadow "$RAW" "$TRINO_FAIL"
  [ "$status" -eq 0 ]
  fired=$(printf '%s' "$output" | jq -c --arg id cr-javon '.signal_review[]|select(.cr_id==$id)._fraud.fired')
  [[ "$fired" == *'"role_inflation"'* ]]
  [[ "$fired" == *'"establishment"'* ]]
  [[ "$fired" == *'"velocity"'* ]]
}

# ───────────────────────── fail-soft Trino ─────────────────────────

@test "fail-soft Trino: helper exits 1 ⇒ muso_only unavailable, batch still scores, exit 0" {
  run_scorer shadow "$RAW" "$TRINO_FAIL"
  [ "$status" -eq 0 ]
  # muso_only_available is false on every annotated credit.
  avail=$(printf '%s' "$output" | jq -r '[.signal_approve[],.signal_review[]]|map(._fraud.muso_only_available)|all')
  [ "$avail" = "false" ]
  # muso_only NEVER appears in any fired list when Trino is down.
  has_muso=$(printf '%s' "$output" | jq -r '[.signal_approve[],.signal_review[]]|map(._fraud.fired[])|any(.=="muso_only")')
  [ "$has_muso" = "false" ]
  # The OTHER factors still fire (Ming still has role_inflation/establishment).
  fired=$(printf '%s' "$output" | jq -c --arg id cr-ming '.signal_approve[]|select(.cr_id==$id)._fraud.fired')
  [[ "$fired" == *'"role_inflation"'* ]]
}

@test "fail-soft Trino: a loud UNAVAILABLE diagnostic reaches stderr" {
  run_scorer shadow "$RAW" "$TRINO_FAIL"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"UNAVAILABLE this run"* ]]
}

@test "fail-soft Trino under enforce: batch is never blocked, still exits 0 and produces buckets" {
  # With Trino down, Ming falls short of threshold (no muso_only weight), so no
  # downgrade — the point is the batch SURVIVES the Trino failure.
  run_scorer enforce "$RAW" "$TRINO_FAIL"
  [ "$status" -eq 0 ]
  # Every signal_approve credit stayed approve (none crossed threshold).
  [ "$(printf '%s' "$output" | jq -r '.signal_approve|length')" = "3" ]
  [ "$(printf '%s' "$output" | jq -r '.counts.signal_approve')" = "3" ]
}

# ───────────────────────── missing raw batch ─────────────────────────

@test "missing CV_FRAUD_RAW_BATCH (shadow) ⇒ fail-soft pass-through, verdicts unchanged" {
  run_scorer shadow "-" "$TRINO_OK"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"FAIL-SOFT"* ]]
  # No annotations added.
  run jq -e '.signal_approve[0]|has("_fraud")' <<<"$output"
  [ "$status" -ne 0 ]
  run jq -e 'has("signal_fraud")' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "unreadable CV_FRAUD_RAW_BATCH (enforce) ⇒ fail-soft pass-through" {
  run --separate-stderr env CV_FRAUD_MODE=enforce \
    CV_FRAUD_RAW_BATCH="$TEST_TMPDIR/does-not-exist.json" TRINO_QUERY_SH="$TRINO_OK" \
    bash -c "'$SCORER' < '$SCORED'"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"FAIL-SOFT"* ]]
  run jq -e 'has("signal_fraud")' <<<"$output"
  [ "$status" -ne 0 ]
}

# ───────────────────────── reason string format ─────────────────────────

@test "reason string: names fired factors in fixed order with =score (2dp), only when over threshold" {
  run_scorer enforce "$RAW" "$TRINO_OK"
  [ "$status" -eq 0 ]
  reason=$(printf '%s' "$output" | jq -r --arg id cr-ming '.signal_fraud[]|select(.cr_id==$id)._fraud.reason')
  # Exact reason for Ming with muso=80: role_inflation+source_quality+establishment+muso_only=0.67
  [ "$reason" = "fraud:role_inflation+source_quality+establishment+muso_only=0.67" ]
  # _signal.reason mirrors _fraud.reason on the downgraded credit.
  sig_reason=$(printf '%s' "$output" | jq -r --arg id cr-ming '.signal_fraud[]|select(.cr_id==$id)._signal.reason')
  [ "$sig_reason" = "$reason" ]
}

@test "reason string: null for a not-over-threshold credit" {
  run_scorer shadow "$RAW" "$TRINO_OK"
  [ "$status" -eq 0 ]
  # Roberto fires only source_quality (under threshold) → reason is null.
  reason=$(printf '%s' "$output" | jq -r --arg id cr-roberto '.signal_approve[]|select(.cr_id==$id)._fraud.reason')
  [ "$reason" = "null" ]
}

# ───────────────────────── Trino availability semantics ─────────────────────────
# Regression for the inverted fail-soft bug: a HEALTHY Trino that returns ZERO
# rows (the common clean case) must report muso_only_available=true, NOT false.
# Availability comes from the helper's {available,data} wrapper, never from
# whether the data map is empty.

@test "healthy Trino zero-rows ⇒ muso_only_available is TRUE (no spurious 'unavailable')" {
  ZEROROW="$TEST_TMPDIR/trino-zero.sh"
  cat > "$ZEROROW" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
  chmod +x "$ZEROROW"
  run_scorer shadow "$RAW" "$ZEROROW"
  [ "$status" -eq 0 ]
  avail=$(printf '%s' "$output" | jq -r '[.signal_approve[],.signal_review[]]|map(._fraud.muso_only_available)|all')
  [ "$avail" = "true" ]
  # And the loud UNAVAILABLE diagnostic must NOT have fired on a healthy run.
  [[ "$stderr" != *"UNAVAILABLE this run"* ]]
}

@test "down Trino ⇒ muso_only_available is FALSE (genuine unavailable)" {
  run_scorer shadow "$RAW" "$TRINO_FAIL"
  [ "$status" -eq 0 ]
  avail=$(printf '%s' "$output" | jq -r '[.signal_approve[],.signal_review[]]|map(._fraud.muso_only_available)|any')
  [ "$avail" = "false" ]
}

# ───────────────────────── cross-step integration ─────────────────────────
# These exercise score-fraud-signals.sh → verdict-engine.sh → the renderer /
# apply step. The unit tests above cover the scorer in isolation; these lock the
# contracts BETWEEN steps (the gap that let the shadow-drop blocker and the dead
# post-hoc path ship in the first review round).

VERDICT="$SCRIPTS_DIR/lobster-mvp/verdict-engine.sh"
RENDER="$SCRIPTS_DIR/lobster-mvp/render-dry-run-summary.sh"
APPLY="$SCRIPTS_DIR/lobster-mvp/apply-verdicts.sh"

# Run scorer → verdict-engine, echo the verdict JSON.
chain_verdicts() {
  local mode="$1" trino="$2"
  env CV_FRAUD_MODE="$mode" CV_FRAUD_RAW_BATCH="$RAW" TRINO_QUERY_SH="$trino" \
    bash -c "'$SCORER' < '$SCORED'" 2>/dev/null | bash "$VERDICT" 2>/dev/null
}

@test "integration shadow: render surfaces the FRAUD (SHADOW) section and verdicts are UNCHANGED" {
  v=$(chain_verdicts shadow "$TRINO_OK")
  # verdict-engine must carry the top-level signal_fraud array through (the blocker fix).
  [ "$(printf '%s' "$v" | jq -r '.signal_fraud|length')" = "1" ]
  # Verdicts unchanged: Ming still in would_approve, would_uvn unchanged.
  [ "$(printf '%s' "$v" | jq -r '.counts.would_approve')" = "3" ]
  # Renderer prints the shadow-labelled fraud header.
  out=$(printf '%s' "$v" | POST_PARENT_TO_CHANNEL=0 THREAD_TS= CV_FRAUD_MODE=shadow bash "$RENDER" 2>/dev/null)
  [[ "$out" == *"SUSPECTED FRAUD (SHADOW"* ]]
}

@test "integration enforce: Ming is downgraded into would_uvn and the renderer flags it (no SHADOW label)" {
  v=$(chain_verdicts enforce "$TRINO_OK")
  [ "$(printf '%s' "$v" | jq -r '.counts.would_approve')" = "2" ]
  in_uvn=$(printf '%s' "$v" | jq -r '[.would_uvn[]|select(.cr_id=="cr-ming")]|length')
  [ "$in_uvn" = "1" ]
  out=$(printf '%s' "$v" | POST_PARENT_TO_CHANNEL=0 THREAD_TS= CV_FRAUD_MODE=enforce bash "$RENDER" 2>/dev/null)
  [[ "$out" == *"SUSPECTED FRAUD"* ]]
  [[ "$out" != *"SHADOW"* ]]
}

@test "integration off: renderer prints NO fraud section" {
  v=$(chain_verdicts off "$TRINO_OK")
  out=$(printf '%s' "$v" | POST_PARENT_TO_CHANNEL=0 THREAD_TS= CV_FRAUD_MODE=off bash "$RENDER" 2>/dev/null)
  [[ "$out" != *"SUSPECTED FRAUD"* ]]
}

@test "integration apply: the fraud UVN subset is PUT with flag_reason=fraud_multifactor, plain UVN is not" {
  CAP="$TEST_TMPDIR/api-calls.log"
  : > "$CAP"
  STUB="$TEST_TMPDIR/admin-api.sh"
  cat > "$STUB" <<STUB
#!/usr/bin/env bash
echo "FLAG=[\${OPS_FLAG_REASON:-}]" >> "$CAP"
printf '{"http_status":"200","dryRun":false}\n'
STUB
  chmod +x "$STUB"
  v=$(chain_verdicts enforce "$TRINO_OK")
  printf '%s' "$v" | env ADMIN_API_SH="$STUB" OPS_LOBSTER_APPLY_LOG="$TEST_TMPDIR/apply.jsonl" \
    bash "$APPLY" false >/dev/null 2>&1
  # The fraud chunk carried the marker...
  grep -q 'FLAG=\[fraud_multifactor\]' "$CAP"
  # ...and at least one non-fraud call (approve and/or plain UVN) did NOT.
  grep -q 'FLAG=\[\]' "$CAP"
}

# ───────────────────────── safety-property locks (inline fixtures) ─────────────────────────
# These use self-contained one-off fixtures (not fixtures/fraud/) so the shared
# fixture's bucket counts — asserted exactly by the tests above — never move.

@test "backend_hard_reject fires ALONE on an otherwise-clean profile (under threshold, no downgrade)" {
  # A profile that is established (cc=500, pop=80), industry-sourced, creative
  # single role, no velocity — but the backend set a hard-reject rule
  # (reject_artist_credit=1). The factor must fire by itself: it is the only
  # signal the scorer takes from the backend's own rejection rules, so if it
  # silently stopped firing, a backend-rejected profile could read as clean.
  # Alone it is 3/15 = 0.2 < 0.60 — visibility, not an automatic downgrade.
  local raw="$TEST_TMPDIR/hard-raw.json" scored="$TEST_TMPDIR/hard-scored.json"
  cat > "$raw" <<'JSON'
{ "queue_depth": 1, "fetch_size": 1, "items": [
  { "id": "cr-hard", "profileId": "55555555-5555-5555-5555-555555555555",
    "createdAt": "2026-06-01T00:00:00Z", "status": "unverified",
    "credits": ["Producer"],
    "metadata": { "source": "industry", "label": "Reputable Label", "isrc": "USHARD0001" },
    "profile": { "creditCount": 500, "popularity": 80, "name": "Hard Reject" },
    "verificationData": { "total_risk_percent": "60", "rule_risk_percent": {
      "reject_artist_credit": "1", "reject_high_velocity_profile": "0",
      "reject_high_risk_profile": "0", "reject_deleted_catalog_track": "0",
      "reject_individual_org_credit": "0", "reject_publisher_label_credit": "0" } } }
] }
JSON
  cat > "$scored" <<'JSON'
{ "queue_depth": 1, "fetch_size": 1,
  "counts": { "total": 1, "signal_approve": 1, "signal_review": 0, "signal_uvn": 0 },
  "signal_approve": [
    { "cr_id": "cr-hard", "profile_id": "55555555-5555-5555-5555-555555555555",
      "isrc": "USHARD0001", "credited_name": "Hard Reject", "role": "Producer",
      "_signal": { "bucket": "signal_approve", "reason": "approve_owning_track" } }
  ],
  "signal_review": [], "signal_uvn": []
}
JSON
  run --separate-stderr env CV_FRAUD_MODE=shadow CV_FRAUD_RAW_BATCH="$raw" \
    TRINO_QUERY_SH="$TRINO_FAIL" bash -c "'$SCORER' < '$scored'"
  [ "$status" -eq 0 ]
  fired=$(printf '%s' "$output" | jq -c '.signal_approve[0]._fraud.fired')
  [ "$fired" = '["backend_hard_reject"]' ]
  [ "$(printf '%s' "$output" | jq -r '.signal_approve[0]._fraud.over')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.signal_approve[0]._fraud.factors.backend_hard_reject')" = "0.2" ]
}

@test "enforce is ESCALATION-ONLY: a fraudulent signal_uvn credit stays UVN (with audit marker), never reaches would_approve" {
  # The other direction of the downgrade safety property: fraud can only
  # TIGHTEN a verdict (anything → UVN), never loosen one. A credit the backend
  # already bucketed signal_uvn that also trips the fraud threshold must move
  # to signal_fraud (orig_bucket preserved for audit) and still terminate in
  # would_uvn — and must never surface in would_approve. The clean approve
  # credit in the same batch is untouched.
  local raw="$TEST_TMPDIR/esc-raw.json" scored="$TEST_TMPDIR/esc-scored.json"
  cat > "$raw" <<'JSON'
{ "queue_depth": 2, "fetch_size": 2, "items": [
  { "id": "cr-scam", "profileId": "66666666-6666-6666-6666-666666666666",
    "createdAt": "2026-06-05T00:00:00Z", "status": "unverified",
    "credits": ["Editorial", "Photography", "Art", "Design", "Marketing", "Management", "Publisher"],
    "metadata": { "source": "spclient", "label": "Shell Co", "isrc": "USSCAM0001" },
    "profile": { "creditCount": 10, "popularity": 5, "name": "Scam Profile" },
    "verificationData": { "total_risk_percent": "80", "rule_risk_percent": {
      "reject_artist_credit": "1", "reject_high_velocity_profile": "1",
      "reject_high_risk_profile": "0", "reject_deleted_catalog_track": "0",
      "reject_individual_org_credit": "0", "reject_publisher_label_credit": "0" } } },
  { "id": "cr-clean", "profileId": "77777777-7777-7777-7777-777777777777",
    "createdAt": "2024-01-01T00:00:00Z", "status": "unverified",
    "credits": ["Producer", "Mixer"],
    "metadata": { "source": "industry", "label": "Reputable Label", "isrc": "USCLEAN001" },
    "profile": { "creditCount": 540, "popularity": 75, "name": "Clean Producer" },
    "verificationData": { "total_risk_percent": "2", "rule_risk_percent": {
      "reject_artist_credit": "0", "reject_high_velocity_profile": "0",
      "reject_high_risk_profile": "0", "reject_deleted_catalog_track": "0",
      "reject_individual_org_credit": "0", "reject_publisher_label_credit": "0" } } }
] }
JSON
  cat > "$scored" <<'JSON'
{ "queue_depth": 2, "fetch_size": 2,
  "counts": { "total": 2, "signal_approve": 1, "signal_review": 0, "signal_uvn": 1 },
  "signal_approve": [
    { "cr_id": "cr-clean", "profile_id": "77777777-7777-7777-7777-777777777777",
      "isrc": "USCLEAN001", "credited_name": "Clean Producer", "role": "Producer",
      "_signal": { "bucket": "signal_approve", "reason": "approve_owning_track" } }
  ],
  "signal_review": [],
  "signal_uvn": [
    { "cr_id": "cr-scam", "profile_id": "66666666-6666-6666-6666-666666666666",
      "isrc": "USSCAM0001", "credited_name": "Scam Profile", "role": "Editorial",
      "_signal": { "bucket": "signal_uvn", "reason": "risk=80" } }
  ]
}
JSON
  # role+src+est+vel+hard = 12/15 = 0.8 ≥ 0.60 even with Trino down.
  run --separate-stderr env CV_FRAUD_MODE=enforce CV_FRAUD_RAW_BATCH="$raw" \
    TRINO_QUERY_SH="$TRINO_FAIL" bash -c "'$SCORER' < '$scored'"
  [ "$status" -eq 0 ]
  # cr-scam moved signal_uvn → signal_fraud, original bucket on the audit trail.
  [ "$(printf '%s' "$output" | jq -r '.signal_uvn|length')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r '.signal_fraud[0].cr_id')" = "cr-scam" ]
  [ "$(printf '%s' "$output" | jq -r '.signal_fraud[0]._fraud.orig_bucket')" = "signal_uvn" ]
  # The clean approve credit is untouched.
  [ "$(printf '%s' "$output" | jq -r '.counts.signal_approve')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.signal_approve[0].cr_id')" = "cr-clean" ]
  # Through the verdict engine: cr-scam terminates in would_uvn, NEVER would_approve.
  v=$(env CV_FRAUD_MODE=enforce CV_FRAUD_RAW_BATCH="$raw" TRINO_QUERY_SH="$TRINO_FAIL" \
    bash -c "'$SCORER' < '$scored'" 2>/dev/null | bash "$VERDICT" 2>/dev/null)
  [ "$(printf '%s' "$v" | jq -r '[.would_uvn[]|select(.cr_id=="cr-scam")]|length')" = "1" ]
  [ "$(printf '%s' "$v" | jq -r '[.would_approve[]|select(.cr_id=="cr-scam")]|length')" = "0" ]
  [ "$(printf '%s' "$v" | jq -r '.would_approve|length')" = "1" ]
}

@test "raw batch with non-array .items ⇒ fail-soft pass-through (type-check, not truthiness)" {
  # Regression: `jq -e '.items'` passes for ANY truthy .items (object, string),
  # and the batch then aborted inside the group_by() scoring program instead of
  # passing through unchanged — violating the raw-batch fail-soft contract.
  BADRAW="$TEST_TMPDIR/bad-items.json"
  printf '{ "queue_depth": 1, "fetch_size": 1, "items": { "oops": "not-an-array" } }\n' > "$BADRAW"
  run_scorer shadow "$BADRAW" "$TRINO_OK"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"FAIL-SOFT"* ]]
  # Pass-through unchanged: no annotations, no signal_fraud.
  run jq -e '.signal_approve[0]|has("_fraud")' <<<"$output"
  [ "$status" -ne 0 ]
  run jq -e 'has("signal_fraud")' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "shadow never writes a durable fraud marker: over-threshold UVN credit is PUT as PLAIN uvn (no fraud_multifactor)" {
  # Regression: shadow annotates _fraud.over=true on EVERY bucket without
  # re-bucketing. apply-verdicts used to key the uvn_fraud chunk on
  # ._fraud.over as well as the bucket, so an already-UVN credit that tripped
  # the detector got a durable OPS_FLAG_REASON=fraud_multifactor from a mode
  # that is supposed to be observe-only. The fraud chunk must key ONLY on the
  # enforce-only re-bucket (._signal.bucket == "signal_fraud").
  local raw="$TEST_TMPDIR/shadow-uvn-raw.json" scored="$TEST_TMPDIR/shadow-uvn-scored.json"
  cat > "$raw" <<'JSON'
{ "queue_depth": 1, "fetch_size": 1, "items": [
  { "id": "cr-scam", "profileId": "66666666-6666-6666-6666-666666666666",
    "createdAt": "2026-06-05T00:00:00Z", "status": "unverified",
    "credits": ["Editorial", "Photography", "Art", "Design", "Marketing", "Management", "Publisher"],
    "metadata": { "source": "spclient", "label": "Shell Co", "isrc": "USSCAM0001" },
    "profile": { "creditCount": 10, "popularity": 5, "name": "Scam Profile" },
    "verificationData": { "total_risk_percent": "80", "rule_risk_percent": {
      "reject_artist_credit": "1", "reject_high_velocity_profile": "1",
      "reject_high_risk_profile": "0", "reject_deleted_catalog_track": "0",
      "reject_individual_org_credit": "0", "reject_publisher_label_credit": "0" } } }
] }
JSON
  cat > "$scored" <<'JSON'
{ "queue_depth": 1, "fetch_size": 1,
  "counts": { "total": 1, "signal_approve": 0, "signal_review": 0, "signal_uvn": 1 },
  "signal_approve": [], "signal_review": [],
  "signal_uvn": [
    { "cr_id": "cr-scam", "profile_id": "66666666-6666-6666-6666-666666666666",
      "isrc": "USSCAM0001", "credited_name": "Scam Profile", "role": "Editorial",
      "_signal": { "bucket": "signal_uvn", "reason": "risk=80" } }
  ]
}
JSON
  CAP="$TEST_TMPDIR/shadow-api-calls.log"
  : > "$CAP"
  STUB="$TEST_TMPDIR/shadow-admin-api.sh"
  cat > "$STUB" <<STUB
#!/usr/bin/env bash
echo "FLAG=[\${OPS_FLAG_REASON:-}]" >> "$CAP"
printf '{"http_status":"200","dryRun":false}\n'
STUB
  chmod +x "$STUB"
  v=$(env CV_FRAUD_MODE=shadow CV_FRAUD_RAW_BATCH="$raw" TRINO_QUERY_SH="$TRINO_FAIL" \
    bash -c "'$SCORER' < '$scored'" 2>/dev/null | bash "$VERDICT" 2>/dev/null)
  # Precondition of the bug: the UVN credit IS over threshold (role+src+est+vel+hard
  # = 12/15 = 0.8) yet shadow kept its bucket.
  [ "$(printf '%s' "$v" | jq -r '[.would_uvn[]|select(.cr_id=="cr-scam")][0]._fraud.over')" = "true" ]
  [ "$(printf '%s' "$v" | jq -r '[.would_uvn[]|select(.cr_id=="cr-scam")][0]._signal.bucket')" = "signal_uvn" ]
  printf '%s' "$v" | env ADMIN_API_SH="$STUB" OPS_LOBSTER_APPLY_LOG="$TEST_TMPDIR/shadow-apply.jsonl" \
    bash "$APPLY" false >/dev/null 2>&1
  # The PUT landed as PLAIN uvn — no fraud marker anywhere in the capture.
  grep -q 'FLAG=\[\]' "$CAP"
  ! grep -q 'fraud_multifactor' "$CAP"
}

@test "degraded-but-CLEAN run still announces the missing muso-only factor (FRAUD_COUNT==0)" {
  # Regression: the renderer's Trino-unavailable warning lived inside the
  # FRAUD_COUNT>0 branch and was computed over fraud-flagged credits only, so
  # a down-Trino run where the missing factor kept every profile below
  # threshold looked identical to a fully scored clean batch. The warning must
  # render from ALL annotated credits even when nothing was flagged.
  v=$(chain_verdicts shadow "$TRINO_FAIL")
  # Precondition: with muso_only unavailable nothing crosses the threshold.
  [ "$(printf '%s' "$v" | jq -r '.signal_fraud|length')" = "0" ]
  out=$(printf '%s' "$v" | POST_PARENT_TO_CHANNEL=0 THREAD_TS= CV_FRAUD_MODE=shadow bash "$RENDER" 2>/dev/null)
  [[ "$out" != *"SUSPECTED FRAUD"* ]]
  [[ "$out" == *"muso-only Trino signal was UNAVAILABLE this run"* ]]
}

@test "healthy run and off mode post NO muso-only unavailable warning" {
  v=$(chain_verdicts shadow "$TRINO_OK")
  out=$(printf '%s' "$v" | POST_PARENT_TO_CHANNEL=0 THREAD_TS= CV_FRAUD_MODE=shadow bash "$RENDER" 2>/dev/null)
  [[ "$out" != *"UNAVAILABLE"* ]]
  # off: no _fraud annotations exist at all — vacuously no warning.
  v2=$(chain_verdicts off "$TRINO_FAIL")
  out2=$(printf '%s' "$v2" | POST_PARENT_TO_CHANNEL=0 THREAD_TS= CV_FRAUD_MODE=off bash "$RENDER" 2>/dev/null)
  [[ "$out2" != *"UNAVAILABLE"* ]]
}
