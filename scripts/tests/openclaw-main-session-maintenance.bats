#!/usr/bin/env bats
# Pins openclaw-main.json session.maintenance (MUS-3737 F2).
#
# pruneAfter is 48h, not 14d: a 14d window kept ~2 weeks of session entries for
# the gateway to scan at every restart. The other five keys are the caps paid
# for by three cron-wedge outages (CLAUDE.md) and must not drift; the key-count
# check stops a new key being slipped in unreviewed.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
CONF="$HYDRA_REPO/openclaw-main.json"

@test "session.maintenance.pruneAfter is 48h" {
  run jq -r '.session.maintenance.pruneAfter' "$CONF"
  [ "$status" -eq 0 ]
  [ "$output" = "48h" ]
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
