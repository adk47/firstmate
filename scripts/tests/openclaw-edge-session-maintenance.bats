#!/usr/bin/env bats
# Pins openclaw-edge.json session.maintenance (MUS-28729, continuing MUS-2652).
#
# pruneAfter is 7d, not 14d: the edge gateway re-parses every session_nodes row
# on each cold start, so the post-restart freeze grows with the row count. The
# edge froze 721 s, 751 s, 769 s and 788 s across four restarts on 6 Nov 2026
# (node-8 journal), with 2272 rows in agents/support at 14d. 7d keeps about 60%
# of those rows. The other five keys are the caps paid for by past cron-wedge
# outages and must not drift; the key-count check stops a new key being slipped
# in unreviewed.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
CONF="$HYDRA_REPO/openclaw-edge.json"

@test "session.maintenance.pruneAfter is 7d" {
  run jq -r '.session.maintenance.pruneAfter' "$CONF"
  [ "$status" -eq 0 ]
  [ "$output" = "7d" ]
}

@test "the other five maintenance keys are unchanged" {
  run jq -r '.session.maintenance | [.mode, .maxEntries, .resetArchiveRetention, .maxDiskBytes, .highWaterBytes] | map(tostring) | join(",")' "$CONF"
  [ "$status" -eq 0 ]
  [ "$output" = "enforce,10000,7d,8gb,6gb" ]
}

@test "session.maintenance has exactly six keys" {
  run jq -r '.session.maintenance | keys | length' "$CONF"
  [ "$status" -eq 0 ]
  [ "$output" = "6" ]
}
