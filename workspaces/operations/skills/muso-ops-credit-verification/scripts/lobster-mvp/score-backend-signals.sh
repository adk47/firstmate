#!/usr/bin/env bash
# score-backend-signals.sh — Lobster step: partition fetch-queue items by
# the deterministic backend-signals verdict.
#
# Stdin:  fetch-queue.sh output {queue_depth, fetch_size, items: [...]}
# Stdout: {queue_depth, fetch_size,
#          counts: {total, signal_approve, signal_review, signal_uvn},
#          signal_approve: [credit, ...],   ← high-confidence backend approve
#          signal_review:  [credit, ...],   ← no strong approve signal, no hard reject
#          signal_uvn:     [credit, ...]}   ← can't evaluate / backend says no
#
# verdict-engine.sh routes signal_approve → would_approve; both
# signal_review and signal_uvn → would_uvn (MusicBrainz lookup was
# removed 2026-05-18 because mb_confirmed=0 across runs — see
# ba836ac).
#
# Policy (rewritten 2026-10-11, firstmate task ai-credit-validator-h1):
#
#   signal_approve   ONLY when the IDP validator ITSELF approved the request:
#                    verificationData.is_approved == true
#                    AND total_risk_percent < 30 (the validator's APPROVE_THRESHOLD)
#                    AND no reject_* / review_* (hold) rule fired
#                    AND no rule_errors
#                    AND track_pending_capture != 100.
#                    This pipeline never approves a request the validator
#                    declined or held.
#
#   signal_uvn       if rule_risk_percent.track_pending_capture == 100
#                    OR no verificationData at all
#                    OR any hard-reject (reject_*) or hold (review_*) rule fired
#                    → can't evaluate, or the backend already says no
#
#   signal_review    everything else, i.e. the validator declined it
#                    (is_approved != true). Downstream this is treated the same
#                    as signal_uvn (both route to user_verification_needed).
#
# WHY THE OLD RULE WAS WRONG (do not reintroduce it). From 2026-05-18
# (#290) until 2026-10-11 the rule was
#   approve_owning_track == 100 AND total_risk_percent < 80.
# In the IDP validator (processors/raw/validation/user_credit_validator.py),
# an approve_* rule FIRES when its risk is BELOW APPROVE_THRESHOLD (30).
# approve_owning_track == 100 therefore means the owning-track shortcut did
# NOT fire. The queue this pipeline drains (status=unverified) holds rows the
# validator declined (risk >= 30), so the old rule meant "approve any declined
# row with risk 30-80 and no reject signal". The "99.34% precision" backtest
# was circular: it scored rows that ended up approved, most of them approved by
# the validator itself or by this pipeline. Example: a Producer claim on a
# Taylor Swift single, risk 58.26, collaborations 100 (the submitter had never
# worked with anyone on the track). The validator declined it and this
# pipeline approved it on 2026-10-11 at 00:01Z.
#
# Pure jq. No I/O. No side effects. Fully testable from a static fixture.

set -euo pipefail

INPUT=$(cat)

QUEUE_DEPTH=$(echo "$INPUT" | jq -r '.queue_depth // 0')
FETCH_SIZE=$(echo "$INPUT" | jq -r '.fetch_size // 0')

# Single jq program does all the work. Each item gets a `_bucket` tag, then
# we partition. Reasoning is preserved per-credit for the summary renderer.
echo "$INPUT" | jq -c --argjson qd "$QUEUE_DEPTH" --argjson fs "$FETCH_SIZE" '
  def num(p): (p | tonumber? // 0);

  def classify:
    . as $c
    | (.verificationData // {} | if type == "object" then . else {} end) as $vd
    | ($vd.rule_risk_percent // {}) as $rrp_raw
    | (if ($rrp_raw | type) == "object" then $rrp_raw else {} end) as $rrp
    | num($rrp.track_pending_capture)        as $tpc
    | num($vd.total_risk_percent)            as $trp
    # Any reject_* (auto-reject) or review_* (IDP #1686 hold) rule with a
    # non-zero risk blocks approval. Match by prefix so a newly added rule of
    # either kind is covered without editing this file. A non-numeric value is
    # treated as fired (fail closed).
    | (if ($rrp_raw | type) != "object" then true
       else ([$rrp | to_entries[]
              | select(.key | test("^(reject|review)_"))
              | select((.value | tonumber? // 100) > 0)] | length > 0)
       end) as $blocked
    | (($vd.total_risk_percent | type) == "number") as $has_risk
    | (($vd.rule_errors // {}) | if type == "object" then length > 0 else true end) as $has_errors
    | ($vd.is_approved == true) as $validator_approved
    | if ($vd == {} or $vd == null) then
        {bucket: "signal_uvn", reason: "no_verification_data", validator_approved: false}
      elif $tpc == 100 then
        {bucket: "signal_uvn", reason: "track_pending_capture", validator_approved: $validator_approved}
      elif $blocked then
        {bucket: "signal_uvn", reason: "hard_reject_or_hold_signal", validator_approved: $validator_approved}
      elif $validator_approved and $has_risk and ($trp < 30) and ($has_errors | not) then
        {bucket: "signal_approve",
         reason: "validator_approved,risk=\($trp|tostring)",
         validator_approved: true,
         total_risk_percent: $trp}
      else
        {bucket: "signal_review",
         reason: (if $validator_approved then "validator_approved_but_errors_or_risk,risk=\($trp|tostring)"
                  else "validator_declined,risk=\($trp|tostring)" end),
         validator_approved: $validator_approved,
         total_risk_percent: $trp}
      end;

  def minimal: {
    cr_id: .id,
    profile_id: .profileId,
    isrc: (.metadata.isrc // null),
    credited_name: (.profile.name // .claimName // ""),
    role: ((.credits // []) | join(",")),
    _signal: classify
  };

  (.items // []) as $items
  | (.selector // null) as $selector
  | ($items | map(minimal)) as $tagged
  | {
      queue_depth: $qd,
      fetch_size: $fs,
      selector: $selector,
      counts: {
        total: ($tagged | length),
        signal_approve: ($tagged | map(select(._signal.bucket == "signal_approve")) | length),
        signal_review:  ($tagged | map(select(._signal.bucket == "signal_review"))  | length),
        signal_uvn:     ($tagged | map(select(._signal.bucket == "signal_uvn"))     | length)
      },
      signal_approve: ($tagged | map(select(._signal.bucket == "signal_approve"))),
      signal_review:  ($tagged | map(select(._signal.bucket == "signal_review"))),
      signal_uvn:     ($tagged | map(select(._signal.bucket == "signal_uvn")))
    }'
