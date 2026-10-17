#!/usr/bin/env bats
# Tests for scripts/ad-screening.sh --run (MUS-3676): Jev call, answer mapping,
# PUT write-back, and the no-guess failure handling. Hermetic: muso-read, jev.sh
# and the PUT wrapper are stubbed; the stubs record what would be sent.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/ad-screening.sh"
FLAGS=(prohibited_category misleading_claims artist_impersonation adult gambling crypto_financial_promises other_harm)

setup() {
  T="$BATS_TEST_TMPDIR"
  export STUB_DIR="$T"
  export AD_SCREENING_MUSO_READ="$T/muso-read" AD_SCREENING_DESCRIBE="$T/describe"
  export AD_SCREENING_JEV="$T/jev" AD_SCREENING_PUT="$T/put"
  export AD_SCREENING_DISABLED_FILE="$T/ad-screening.disabled"
  export STUB_FIXTURE="$T/fixture.json" STUB_ANSWERS="$T/answers.json"
  # Fence off real Slack (hydra#1195): recorder muso, absent env file, no token.
  export MUSO_BIN="$T/muso-recorder" MUSO_SLACK_ENV_FILE="$T/none.env"
  unset MUSO_SLACK_BOT_TOKEN_CMO MUSO_SLACK_BOT_TOKEN_DEVOPS
  printf '#!/usr/bin/env bash\necho "$*" >>"%s/muso.argv"\nexit 0\n' "$T" >"$MUSO_BIN"
  chmod +x "$MUSO_BIN"
  cat >"$AD_SCREENING_MUSO_READ" <<'S'
#!/usr/bin/env bash
cat "$STUB_FIXTURE"
S
  cat >"$AD_SCREENING_DESCRIBE" <<'S'
#!/usr/bin/env bash
echo "A purple album cover with a silhouette."
S
  # jev stub: records argv, copies the state file, exits STUB_JEV_RC (per-ad override STUB_JEV_RC_<id>).
  cat >"$AD_SCREENING_JEV" <<'S'
#!/usr/bin/env bash
echo "$*" >>"$STUB_DIR/jev.args"
id=""; state=""
while [ $# -gt 0 ]; do case "$1" in --item-id) id="$2";; --state-file) state="$2";; esac; shift; done
cp "$state" "$STUB_DIR/state.$id.json"
rcvar="STUB_JEV_RC_$id"; rc="${!rcvar:-${STUB_JEV_RC:-0}}"
[ -n "${STUB_JEV_ERR:-}" ] && echo "$STUB_JEV_ERR" >&2
[ "$rc" -eq 0 ] && cat "$STUB_ANSWERS"
exit "$rc"
S
  cat >"$AD_SCREENING_PUT" <<'S'
#!/usr/bin/env bash
echo "$*" >>"$STUB_DIR/put.args"
cp "$3" "$STUB_DIR/put.$2.json"
[ -n "${STUB_PUT_ERR:-}" ] && echo "$STUB_PUT_ERR" >&2
exit "${STUB_PUT_RC:-0}"
S
  chmod +x "$AD_SCREENING_MUSO_READ" "$AD_SCREENING_DESCRIBE" "$AD_SCREENING_JEV" "$AD_SCREENING_PUT"
}

ad() {
  jq -n --arg id "$1" '{id:$id, advertiserName:"Acme", adHeadline:"Hear it first", adBody:"New single",
    destinationUrl:"https://acme.example", primaryMediaUrl:"https://cdn.example/a.png",
    updatedAt:"2026-10-05T09:00:00Z", screenedAt:null, adAccount:{name:"Acme"}, campaign:{}}'
}
fixture_add() { jq -s '{items: (.[0].items + .[1:])}' "$STUB_FIXTURE" - >"$T/f" && mv "$T/f" "$STUB_FIXTURE"; }
fixture() { jq -s '{items: .}' >"$STUB_FIXTURE"; }

# answers <rec> <p_rec> <fit> <comma-list of present flags>
answers() {
  local rec="$1" p="$2" fit="$3" present="$4" f c pp out
  out="$(jq -n --arg rec "$rec" --argjson p "$p" --arg fit "$fit" '{
    recommendation:{type:"choice",choice:$rec,probabilities:({approve:0.05,reject:0.05,needs_human:0.05}|.[$rec]=$p)},
    brand_fit:{type:"choice",choice:$fit,probabilities:{($fit):0.8}}}')"
  for f in "${FLAGS[@]}"; do
    case ",$present," in *",$f,"*) c=present; pp=0.9 ;; *) c=absent; pp=0.95 ;; esac
    out="$(jq --arg k "harm_$f" --arg c "$c" --argjson p "$pp" '.[$k]={type:"choice",choice:$c,probabilities:{($c):$p}}' <<<"$out")"
  done
  echo "$out" >"$STUB_ANSWERS"
}
edit_answers() { jq "$1" "$STUB_ANSWERS" >"$T/a" && mv "$T/a" "$STUB_ANSWERS"; }

puts() { if [ -f "$T/put.args" ]; then wc -l <"$T/put.args" | tr -d ' '; else echo 0; fi; }

# Regression for hydra#1195: 34 fixture briefs hit the real #clio_devops per Bats run.
@test "a full --run with no Slack token never execs muso" {
  ad 101 | fixture; answers approve 0.9 strong ""
  run "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 1 ]
  [ ! -e "$T/muso.argv" ]
}

# ── failure handling first: no PUT, ever ──────────────────────────────

@test "rc 6 (kill switch): no PUT, logged skip, batch exits 0" {
  ad 101 | fixture; answers reject 0.9 weak adult
  STUB_JEV_RC=6 run --separate-stderr "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 0 ]
  [[ "$stderr" == *"skipping ad 101"*"rc=6"* ]]
}

@test "rc 2 (network/timeout): no PUT, logged skip" {
  ad 101 | fixture; answers reject 0.9 weak adult
  STUB_JEV_RC=2 run --separate-stderr "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 0 ]
  [[ "$stderr" == *"skipping ad 101"*"rc=2"* ]]
}

@test "rc 3 / 4 / 5: each writes no PUT" {
  ad 101 | fixture; answers reject 0.9 weak adult
  for rc in 3 4 5; do
    STUB_JEV_RC=$rc run --separate-stderr "$SCRIPT" --run
    [ "$status" -eq 0 ]
    [ "$(puts)" -eq 0 ]
    [[ "$stderr" == *"rc=$rc"* ]]
  done
}

@test "partial answers (recommendation missing) is no answer: no PUT" {
  ad 101 | fixture; answers reject 0.9 weak adult
  edit_answers 'del(.recommendation)'
  run --separate-stderr "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 0 ]
  [[ "$stderr" == *"skipping ad 101"* ]]
}

@test "a missing harm answer is no answer too (cannot claim absent)" {
  ad 101 | fixture; answers approve 0.9 strong ""
  edit_answers 'del(.harm_gambling)'
  run "$SCRIPT" --run
  [ "$(puts)" -eq 0 ]
}

@test "recommendation outside the vocabulary is no answer" {
  ad 101 | fixture; answers reject 0.9 weak adult
  edit_answers '.recommendation.choice="maybe"'
  run "$SCRIPT" --run
  [ "$(puts)" -eq 0 ]
}

@test "selected class with no numeric probability is no answer (no invented confidence)" {
  ad 101 | fixture; answers reject 0.9 weak adult
  edit_answers '.recommendation.probabilities={"approve":0.1}'
  run "$SCRIPT" --run
  [ "$(puts)" -eq 0 ]
}

@test "one ad failing does not stop the batch" {
  { ad 101; ad 102; ad 103; } | fixture; answers reject 0.9 weak adult
  STUB_JEV_RC_102=2 run "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 2 ]
  [ -f "$T/put.101.json" ] && [ -f "$T/put.103.json" ] && [ ! -f "$T/put.102.json" ]
}

@test "a failed PUT is logged and does not stop the batch" {
  { ad 101; ad 102; } | fixture; answers reject 0.9 weak adult
  STUB_PUT_RC=3 run --separate-stderr "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 2 ]
  [[ "$stderr" == *"write failed"* ]]
}

# ── mapping ───────────────────────────────────────────────────────────

@test "success: one PUT per ad with the mapped payload" {
  { ad 101; ad 102; } | fixture; answers reject 0.87 weak adult,gambling,misleading_claims
  run "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 2 ]
  p="$T/put.101.json"
  [ "$(jq -r .recommendation "$p")" = reject ]
  [ "$(jq -r .brandFit "$p")" = weak ]
  [ "$(jq -r .confidence "$p")" = 0.87 ]
  [ "$(jq -r .policyVersion "$p")" = v1 ]
  [ -n "$(jq -r .model "$p")" ]
  [ "$(jq -r .reason "$p")" = "$("$HYDRA_REPO/scripts/lib/ad-screening-reason.sh" --recommendation reject --brand-fit weak --flags misleading_claims,adult,gambling)" ]
}

@test "riskFlags is exactly the three present categories, not the four absent" {
  ad 101 | fixture; answers reject 0.9 acceptable adult,gambling,misleading_claims
  run "$SCRIPT" --run
  [ "$(jq -c '.riskFlags|sort' "$T/put.101.json")" = '["adult","gambling","misleading_claims"]' ]
}

@test "confidence is the probability of the SELECTED class, not another class" {
  ad 101 | fixture; answers reject 0.61 acceptable adult
  edit_answers '.recommendation.probabilities={"approve":0.3,"reject":0.61,"needs_human":0.09}'
  run "$SCRIPT" --run
  [ "$(jq -r .confidence "$T/put.101.json")" = 0.61 ]
}

@test "contradictory answers store the effective needs_human with that class's probability" {
  ad 101 | fixture; answers approve 0.9 acceptable adult
  edit_answers '.recommendation.probabilities={"approve":0.9,"reject":0.04,"needs_human":0.06}'
  run "$SCRIPT" --run
  [ "$(jq -r .recommendation "$T/put.101.json")" = needs_human ]
  [ "$(jq -r .confidence "$T/put.101.json")" = 0.06 ]
}

@test "payload carries only keys the PUT wrapper and endpoint accept" {
  ad 101 | fixture; answers approve 0.9 strong ""
  run "$SCRIPT" --run
  [ "$(jq -c 'keys' "$T/put.101.json")" = '["brandFit","confidence","model","policyVersion","reason","recommendation","riskFlags"]' ]
}

@test "PUT kill switch present: no jev call and no PUT, whole run skipped" {
  ad 101 | fixture; ad 102 | fixture_add; answers reject 0.9 weak adult
  touch "$AD_SCREENING_DISABLED_FILE"
  run --separate-stderr "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ ! -f "$T/jev.args" ]
  [ "$(puts)" -eq 0 ]
  [[ "$stderr" == *"disabled"* ]]
}

@test "jev gets an explicit timeout (default 5000 ms, AD_SCREENING_JEV_TIMEOUT_MS overrides)" {
  ad 101 | fixture; answers approve 0.9 strong ""
  run "$SCRIPT" --run
  [[ "$(cat "$T/jev.args")" == *"--timeout-ms 5000"* ]]
  rm "$T/jev.args"
  AD_SCREENING_JEV_TIMEOUT_MS=9000 run "$SCRIPT" --run
  [[ "$(cat "$T/jev.args")" == *"--timeout-ms 9000"* ]]
}

@test "a failed PUT logs the first line of the wrapper's stderr" {
  ad 101 | fixture; answers approve 0.9 strong ""
  STUB_PUT_RC=4 STUB_PUT_ERR="HTTP 400: reason too long" run --separate-stderr "$SCRIPT" --run
  [[ "$stderr" == *"write failed (rc=4)"*"HTTP 400: reason too long"* ]]
}

@test "a failing jev logs the first line of its stderr" {
  ad 101 | fixture; answers approve 0.9 strong ""
  STUB_JEV_RC=2 STUB_JEV_ERR="curl: timed out" run --separate-stderr "$SCRIPT" --run
  [[ "$stderr" == *"jev rc=2"*"curl: timed out"* ]]
}

# ── how jev is called ─────────────────────────────────────────────────

@test "jev is called for the ad with the questions file, shadow logging left on" {
  ad 101 | fixture; answers approve 0.9 strong ""
  run "$SCRIPT" --run
  args="$(cat "$T/jev.args")"
  [[ "$args" == *"--surface ad-screening"* ]]
  [[ "$args" == *"--item-id 101"* ]]
  [[ "$args" == *"--questions-file $HYDRA_REPO/scripts/ad-screening-questions.json"* ]]
  [[ "$args" != *"--no-shadow"* ]]
}

@test "the state file handed to jev holds the fenced packet" {
  ad 101 | fixture; answers approve 0.9 strong ""
  run "$SCRIPT" --run
  jq -e '.. | strings | select(contains("<<<AD_DATA_BEGIN ad=101>>>"))' "$T/state.101.json" >/dev/null
}

@test "--dry-run still calls neither jev nor the PUT" {
  ad 101 | fixture; answers approve 0.9 strong ""
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$T/jev.args" ]
  [ "$(puts)" -eq 0 ]
}

# ── the stored model is the model Jev was asked to use ───────────────

stored_and_sent() { echo "sent: $(grep -o -- '--model [^ ]*' "$T/jev.args") stored: $(jq -r .model "$T/put.101.json")"; }

@test "AD_SCREENING_MODEL override is both sent to jev and stored" {
  ad 101 | fixture; answers approve 0.9 strong ""
  AD_SCREENING_MODEL=custom run "$SCRIPT" --run
  [ "$(stored_and_sent)" = "sent: --model custom stored: custom" ]
}

@test "JEV_MODEL is honoured: sent to jev and stored" {
  ad 101 | fixture; answers approve 0.9 strong ""
  JEV_MODEL=from-env run "$SCRIPT" --run
  [ "$(stored_and_sent)" = "sent: --model from-env stored: from-env" ]
}

@test "default model follows JEV_PROVIDER, sent and stored alike" {
  ad 101 | fixture; answers approve 0.9 strong ""
  run "$SCRIPT" --run
  [ "$(stored_and_sent)" = "sent: --model ~typesafe/jev-latest stored: ~typesafe/jev-latest" ]
  rm "$T/jev.args"
  JEV_PROVIDER=typesafe run "$SCRIPT" --run
  [ "$(stored_and_sent)" = "sent: --model jev-latest stored: jev-latest" ]
}

# ── the real PUT wrapper must accept our payload ──────────────────────

@test "muso-ad-screening.sh allowlist accepts every key the payload carries" {
  ad 101 | fixture; answers approve 0.9 strong ""
  run "$SCRIPT" --run
  printf '#!/usr/bin/env bash\necho "$@" >"%s/muso.args"\n' "$T" >"$T/muso"; chmod +x "$T/muso"
  MUSO_BIN="$T/muso" AD_SCREENING_DISABLED_FILE="$T/none" run "$HYDRA_REPO/skills-all/muso-ad-screening/scripts/muso-ad-screening.sh" put 101 "$T/put.101.json"
  [ "$status" -eq 0 ]
  [[ "$(cat "$T/muso.args")" == "api PUT /admin/ads/101/screening"* ]]
}
