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
# Policy (backtested 2026-05-15 against 90 days of historical credits):
#
#   signal_approve   if verificationData.rule_risk_percent.approve_owning_track == 100
#                    AND verificationData.total_risk_percent < 80
#                    → historical precision 99.34%, catches ~30% of today's queue
#
#   signal_uvn       if rule_risk_percent.track_pending_capture == 100
#                    OR no verificationData at all
#                    OR any hard-reject signal fires
#                    (reject_artist_credit, reject_deleted_catalog_track,
#                     reject_individual_org_credit, reject_publisher_label_credit,
#                     reject_high_risk_profile)
#                    → can't evaluate or backend already says no
#
#   signal_review    everything else — currently treated the same as
#                    signal_uvn downstream (both route to user_verification_needed).
#                    Kept as a separate bucket for visibility / future use.
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
    | (.verificationData // {}) as $vd
    | ($vd.rule_risk_percent // {}) as $rrp
    | num($rrp.approve_owning_track)         as $aot
    | num($rrp.track_pending_capture)        as $tpc
    | num($vd.total_risk_percent)            as $trp
    | (num($rrp.reject_artist_credit) > 0
       or num($rrp.reject_deleted_catalog_track) > 0
       or num($rrp.reject_individual_org_credit) > 0
       or num($rrp.reject_publisher_label_credit) > 0
       or num($rrp.reject_high_risk_profile) > 0) as $hard_reject
    | if ($vd == {} or $vd == null) then
        {bucket: "signal_uvn", reason: "no_verification_data"}
      elif $tpc == 100 then
        {bucket: "signal_uvn", reason: "track_pending_capture"}
      elif $hard_reject then
        {bucket: "signal_uvn", reason: "hard_reject_signal"}
      elif $aot == 100 and $trp < 80 then
        {bucket: "signal_approve",
         reason: "approve_owning_track=100,risk=\($trp|tostring)",
         total_risk_percent: $trp}
      else
        {bucket: "signal_review",
         reason: "no_strong_approve_signal,risk=\($trp|tostring)",
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
