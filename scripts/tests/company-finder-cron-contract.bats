#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  JOB="$(jq -c '.jobs[] | select(.id == "86adfcce-fe8a-4707-9c22-ad2bd4e43260")' "$REPO_ROOT/cron-jobs.json")"
  MESSAGE="$(jq -r '.payload.message' <<<"$JOB")"
}

@test "company-finder cron uses the enforced wrappers exactly once" {
  [ "$(grep -o '/opt/hydra/scripts/company-finder/prep-batch.sh' <<<"$MESSAGE" | wc -l)" -eq 1 ]
  [ "$(grep -o '/opt/hydra/scripts/company-finder/finalize-batch.sh' <<<"$MESSAGE" | wc -l)" -eq 1 ]
}

@test "company-finder cron never instructs lower-level pipeline calls" {
  [[ "$MESSAGE" != *"dedupe-candidates.sh"* ]]
  [[ "$MESSAGE" != *"verify-candidates.sh"* ]]
  [[ "$MESSAGE" != *"ledger.sh"* ]]
}

@test "company-finder cron stays silent after the finalizer posts" {
  [[ "$MESSAGE" == *"If the finalizer succeeds"* ]]
  [[ "$MESSAGE" == *"exactly NO_REPLY and nothing else"* ]]
}

@test "company-finder cron does not finalize an empty batch" {
  [[ "$MESSAGE" == *"If no companies qualify, do not call the finalizer"* ]]
}
