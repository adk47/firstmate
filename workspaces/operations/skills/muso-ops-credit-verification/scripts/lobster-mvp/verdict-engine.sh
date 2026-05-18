#!/usr/bin/env bash
# verdict-engine.sh — Lobster step: produce final per-credit verdicts.
#
# Stdin: score-backend-signals.sh output {queue_depth, fetch_size,
#                                          signal_approve: [...],
#                                          signal_review: [...],
#                                          signal_uvn: [...]}
# Stdout: {queue_depth, fetch_size,
#          counts: {total, would_approve, signal_approve, mb_confirmed,
#                   would_uvn, mb_error},
#          would_approve:  [...],   ← signal_approve only
#          would_uvn:      [...]}   ← signal_review ∪ signal_uvn
#
# Verdict policy (2 outcomes, no MusicBrainz):
#   * signal_approve  → would_approve (PUT status=approved by apply step)
#   * signal_review   → would_uvn     (PUT status=user_verification_needed)
#   * signal_uvn      → would_uvn     (PUT status=user_verification_needed)
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
  | {
      queue_depth:   .queue_depth,
      fetch_size:    .fetch_size,
      selector:      .selector,
      counts: {
        total:           (($sa | length) + ($sr | length) + ($su | length)),
        would_approve:   ($sa | length),
        signal_approve:  ($sa | length),
        mb_confirmed:    0,
        would_uvn:       (($sr | length) + ($su | length)),
        mb_error:        0
      },
      would_approve: $sa,
      would_uvn:     ($sr + $su)
    }'
