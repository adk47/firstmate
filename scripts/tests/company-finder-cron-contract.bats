#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  JOB="$(jq -c '.jobs[] | select(.id == "86adfcce-fe8a-4707-9c22-ad2bd4e43260")' "$REPO_ROOT/cron-jobs.json")"
  MESSAGE="$(jq -r '.payload.message' <<<"$JOB")"
}

@test "company-finder cron uses the atomic stage tools exactly once" {
  [ "$(grep -o 'company_finder_prep' <<<"$MESSAGE" | wc -l)" -eq 1 ]
  [ "$(grep -o 'company_finder_finalize' <<<"$MESSAGE" | wc -l)" -eq 1 ]
  [[ "$MESSAGE" != *"prep-batch.sh"* ]]
  [[ "$MESSAGE" != *"finalize-batch.sh"* ]]
}

@test "company-finder cron never instructs lower-level pipeline calls" {
  [[ "$MESSAGE" != *"dedupe-candidates.sh"* ]]
  [[ "$MESSAGE" != *"verify-candidates.sh"* ]]
  [[ "$MESSAGE" != *"ledger.sh"* ]]
}

@test "company-finder cron stays silent after the finalizer posts" {
  [[ "$MESSAGE" == *'status="posted"'* ]]
  [[ "$MESSAGE" == *"exactly NO_REPLY and nothing else"* ]]
}

@test "company-finder cron stops when prep returns the no-candidates terminal" {
  [[ "$MESSAGE" == *'status="no_candidates"'* ]]
  [[ "$MESSAGE" == *"do not call the finalizer"* ]]
}
