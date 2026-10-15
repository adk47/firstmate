#!/usr/bin/env bats
# Tests for scripts/lib/qa-gh-error-class.sh — turns a failed `gh` error text into
# the one-line CANNOT REVIEW reason. MUS-11176: the skill hard-coded "rate limit
# blocked the review bundle" for EVERY 403, so a secondary limit or a plain
# permission 403 read as an empty quota and sent the reader hunting for one.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/qa-gh-error-class.sh"

PRIMARY='gh: API rate limit exceeded for user ID 5307497. If you reach out to GitHub Support for help, please include the request ID B224:3AC0C9 (HTTP 403)'
SECONDARY='gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)'
OTHER='gh: Resource not accessible by integration (HTTP 403)'

@test "primary quota 403 -> names primary quota, keeps CANNOT REVIEW prefix" {
  run "$SCRIPT" "$PRIMARY"
  [ "$status" -eq 0 ]
  [[ "$output" == "CANNOT REVIEW: "* ]]
  echo "$output" | grep -q 'primary rate limit (hourly quota)'
}

@test "secondary-limit 403 is NOT the quota wording and says the quota may not be empty" {
  run "$SCRIPT" "$SECONDARY"
  [ "$status" -eq 0 ]
  [[ "$output" == "CANNOT REVIEW: "* ]]
  echo "$output" | grep -q 'secondary rate limit (burst)'
  if echo "$output" | grep -qi 'primary rate limit\|quota exhausted'; then false; fi
}

@test "non-rate-limit 403 is reported as a 403 permission failure, not a rate limit" {
  run "$SCRIPT" "$OTHER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'permission or resource error'
  echo "$output" | grep -q 'Resource not accessible'
  if echo "$output" | grep -qi 'rate limit'; then false; fi
}

@test "remaining and reset seen by the caller are printed" {
  QA_GH_RATELIMIT_REMAINING=0 QA_GH_RATELIMIT_RESET=1792073087 run "$SCRIPT" "$PRIMARY"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'x-ratelimit-remaining=0'
  echo "$output" | grep -q '2026-10-15T14:04:47Z'
}

@test "error text on stdin is classified too" {
  run bash -c "printf '%s' \"\$1\" | \"\$2\"" _ "$SECONDARY" "$SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'secondary rate limit (burst)'
}

@test "a non-403 error is unclassified: exit 1, no output (caller keeps its own wording)" {
  run "$SCRIPT" 'gh: Not Found (HTTP 404)'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
