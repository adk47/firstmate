#!/usr/bin/env bats
# score-backend-signals.sh approve rule (rewritten 2026-10-11).
#
# The old rule `approve_owning_track == 100 AND total_risk_percent < 80` was
# INVERTED. In the IDP validator an approve_* rule fires when its risk is below
# 30, so 100 means "did not fire", and the rule approved validator-DECLINED rows.
# The new rule approves only what the validator itself approved.
bats_require_minimum_version 1.5.0
load helpers

SCORE="$SCRIPTS_DIR/lobster-mvp/score-backend-signals.sh"

setup() { setup_tmp_env; }
teardown() { teardown_tmp_env; }

# item <id> <verificationData-json>
item() { jq -nc --arg id "$1" --argjson vd "$2" '{id:$id, profileId:"p", credits:["Producer"], metadata:{isrc:"X"}, profile:{name:"n"}, verificationData:$vd}'; }

score() { # <items...>
  local items; items=$(printf '%s\n' "$@" | jq -sc '.')
  jq -nc --argjson items "$items" '{queue_depth:1, fetch_size:1, items:$items}' | bash "$SCORE"
}

bucket_of() { jq -r --arg id "$2" '[.signal_approve[], .signal_review[], .signal_uvn[]] | map(select(.cr_id==$id))[0]._signal.bucket' <<< "$1"; }

@test "REGRESSION: the Taylor Swift 'Patient Zero' Producer claim (declined, risk 58.26, aot=100) is NOT approved" {
  out=$(score "$(item hogan '{"is_approved":false,"total_risk_percent":58.26,"rule_errors":{},
    "rule_risk_percent":{"approve_owning_track":100,"approve_credit_exists":100,"approve_common_collaborator":100,
    "collaborations":100,"profile_credit":86.4,"reject_artist_credit":0,"reject_high_risk_profile":0}}')")
  [ "$(bucket_of "$out" hogan)" = "signal_review" ]
  [ "$(jq '.counts.signal_approve' <<< "$out")" = "0" ]
}

@test "any validator-declined row with risk 30-80 and no reject signal is never approved" {
  for risk in 30 34.7 50 79.9; do
    out=$(score "$(item r '{"is_approved":false,"total_risk_percent":'"$risk"',"rule_errors":{},"rule_risk_percent":{"approve_owning_track":100}}')")
    [ "$(bucket_of "$out" r)" = "signal_review" ]
  done
}

@test "a row the validator approved (risk < 30, no blocks, no errors) is signal_approve" {
  out=$(score "$(item ok '{"is_approved":true,"total_risk_percent":4,"rule_errors":{},"rule_risk_percent":{"approve_owning_track":0,"reject_artist_credit":0}}')")
  [ "$(bucket_of "$out" ok)" = "signal_approve" ]
  [ "$(jq -r '.signal_approve[0]._signal.validator_approved' <<< "$out")" = "true" ]
}

@test "an IDP #1686 review_* hold blocks approval even when is_approved is true" {
  out=$(score "$(item held '{"is_approved":true,"total_risk_percent":0,"rule_errors":{},"rule_risk_percent":{"review_role_credited_to_other_at_trusted_source":100}}')")
  [ "$(bucket_of "$out" held)" = "signal_uvn" ]
}

@test "reject_* signals, pending capture, missing data, errors and missing risk never approve" {
  out=$(score \
    "$(item rej '{"is_approved":true,"total_risk_percent":1,"rule_errors":{},"rule_risk_percent":{"reject_high_risk_profile":100}}')" \
    "$(item tpc '{"is_approved":true,"total_risk_percent":1,"rule_errors":{},"rule_risk_percent":{"track_pending_capture":100}}')" \
    "$(item err '{"is_approved":true,"total_risk_percent":1,"rule_errors":{"popularity":"boom"},"rule_risk_percent":{}}')" \
    "$(item norisk '{"is_approved":true,"rule_errors":{},"rule_risk_percent":{}}')" \
    "$(item badrrp '{"is_approved":true,"total_risk_percent":1,"rule_errors":{},"rule_risk_percent":"oops"}')" \
    "$(item odd '{"is_approved":true,"total_risk_percent":1,"rule_errors":{},"rule_risk_percent":{"reject_new_rule":"yes"}}')" \
    "$(jq -nc '{id:"none", profileId:"p", credits:["Producer"]}')")
  [ "$(jq '.counts.signal_approve' <<< "$out")" = "0" ]
  [ "$(bucket_of "$out" rej)" = "signal_uvn" ]
  [ "$(bucket_of "$out" tpc)" = "signal_uvn" ]
  [ "$(bucket_of "$out" err)" = "signal_review" ]
  [ "$(bucket_of "$out" norisk)" = "signal_review" ]
  [ "$(bucket_of "$out" badrrp)" = "signal_uvn" ]
  [ "$(bucket_of "$out" odd)" = "signal_uvn" ]
  [ "$(bucket_of "$out" none)" = "signal_uvn" ]
}

@test "is_approved must be boolean true, not a truthy string" {
  out=$(score "$(item s '{"is_approved":"true","total_risk_percent":1,"rule_errors":{},"rule_risk_percent":{}}')")
  [ "$(bucket_of "$out" s)" = "signal_review" ]
}
