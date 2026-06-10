#!/usr/bin/env bash
# verdict-engine.sh — Lobster step: produce final per-credit verdicts.
#
# Stdin: score-backend-signals.sh output, optionally annotated by the
#        Phase-2 score-fraud-signals.sh step, i.e.
#        {queue_depth, fetch_size,
#         signal_approve: [...],
#         signal_review: [...],
#         signal_uvn: [...],
#         signal_fraud: [...]}   ← present only when CV_FRAUD_MODE != off
# Stdout: {queue_depth, fetch_size,
#          counts: {total, would_approve, signal_approve, mb_confirmed,
#                   would_uvn, signal_fraud, mb_error},
#          would_approve:  [...],   ← signal_approve only
#          would_uvn:      [...],   ← signal_review ∪ signal_uvn ∪ enforced-fraud
#          signal_fraud:   [...]}   ← carried through verbatim for the renderer
#                                     (shadow: copies in original bucket; enforce:
#                                     the same credits that were folded into
#                                     would_uvn). The renderer dedups by cr_id.
#
# Verdict policy (2 terminal outcomes, no MusicBrainz):
#   * signal_approve  → would_approve (PUT status=approved by apply step)
#   * signal_review   → would_uvn     (PUT status=user_verification_needed)
#   * signal_uvn      → would_uvn     (PUT status=user_verification_needed)
#   * signal_fraud    → would_uvn     (PUT status=user_verification_needed)
#
# Fraud handling (score-fraud-signals.sh, gated behind CV_FRAUD_MODE):
#   There is no fraud-specific DB status yet, so a fraud-flagged credit maps to
#   the SAME terminal status as ordinary UVN (user_verification_needed). The
#   credit's _signal.reason ("fraud:<factors>=<score>") and _fraud object ride
#   through unchanged on the object, so the apply step / Slack can distinguish a
#   fraud UVN from an ordinary one and emit a structured flag_reason.
#
#   Only credits whose own _signal.bucket == "signal_fraud" are folded into
#   would_uvn. This is the discriminator that keeps all three CV_FRAUD_MODE
#   states correct WITHOUT this engine needing to read the env var:
#     * off     — no signal_fraud array  → folds nothing, behavior unchanged.
#     * shadow  — signal_fraud holds COPIES whose _signal.bucket is still their
#                 original bucket (signal_approve/review/uvn); they are excluded
#                 here, so verdicts are byte-identical to a no-fraud run (shadow
#                 must not change verdicts) and would_uvn is not double-counted.
#     * enforce — the scorer already MOVED fraud credits out of signal_approve
#                 and set their _signal.bucket = "signal_fraud"; those are folded
#                 in (the auto-approve downgrade actually takes effect).
#
# MB lookup was removed 2026-05-18: zero mb_confirmed approvals on the
# prior real-apply run while consuming ~73% of pipeline wall-clock.
# The mb_confirmed and mb_error count fields are preserved at 0 for
# backward compatibility with render-dry-run-summary.sh (downstream
# consumers can still read them; they just won't ever be non-zero).
#
# Pure jq. No state. No side effects.

set -euo pipefail

INPUT=$(cat)

echo "$INPUT" | jq -c '
  (.signal_approve // []) as $sa
  | (.signal_review  // []) as $sr
  | (.signal_uvn     // []) as $su
  # signal_fraud is present only when CV_FRAUD_MODE != off. Fold into would_uvn
  # ONLY the entries that were actually re-bucketed (enforce). Shadow-mode copies
  # keep their original _signal.bucket and are excluded here so verdicts stay
  # unchanged. The FULL top-level signal_fraud array is carried through
  # separately (below) so the renderer can surface shadow flags too.
  | (.signal_fraud // []) as $sf_all
  | ($sf_all | map(select(._signal.bucket == "signal_fraud"))) as $sf
  | {
      queue_depth:   .queue_depth,
      fetch_size:    .fetch_size,
      selector:      .selector,
      counts: {
        total:           (($sa | length) + ($sr | length) + ($su | length) + ($sf | length)),
        would_approve:   ($sa | length),
        signal_approve:  ($sa | length),
        mb_confirmed:    0,
        would_uvn:       (($sr | length) + ($su | length) + ($sf | length)),
        signal_fraud:    ($sf | length),
        mb_error:        0
      },
      would_approve: $sa,
      would_uvn:     ($sr + $su + $sf),
      # Carried verbatim for render-dry-run-summary.sh. In shadow this is the
      # ONLY place flagged credits surface (they stay in would_approve/etc.); in
      # enforce it duplicates the would_uvn fraud entries, which the renderer
      # dedups by cr_id. Empty/absent in off mode → renders nothing.
      signal_fraud:  $sf_all
    }'
