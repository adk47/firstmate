#!/usr/bin/env bats
# check-data-evidence-no-names.sh — the data/ evidence gate (captain, 2026-11-07).
#
# The jan-gdpr-hide-g1 evidence committed 24 full names next to their erasure
# requests. The doctrine ("Ids only in files and PR text: no requester names",
# scripts/gdpr_pipeline/hide_batch.py:8) is now enforced here, so the next
# hurried commit cannot re-introduce it.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK="$HYDRA_REPO/scripts/check-data-evidence-no-names.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  git -C "$TEST_TMPDIR" init -q
  mkdir -p "$TEST_TMPDIR/data"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

write_data() {
  mkdir -p "$TEST_TMPDIR/data/$(dirname "$1")"
  printf '%s\n' "$2" > "$TEST_TMPDIR/data/$1"
  git -C "$TEST_TMPDIR" add -A
}

run_check() { REPO_ROOT="$TEST_TMPDIR" run bash "$CHECK"; }

@test "a jsonl row carrying tombstone.name next to an erasure request fails" {
  write_data lane/capture.jsonl '{"id": "abc", "tombstone": {"name": "Real Person", "creditCount_before": 9}, "register": [{"class": "privacy_erasure"}]}'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"data/lane/capture.jsonl:1"* ]]
  [[ "$output" == *"tombstone.name"* ]]
  [[ "$output" == *"hide_batch.py:8"* ]]
}

@test "a pretty-printed json object carrying tombstone.name next to an erasure request fails" {
  write_data lane/candidate.json '{
  "class": "privacy_erasure",
  "tombstone": {
    "name": "Real Person",
    "creditCount_before": 9
  }
}'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"data/lane/candidate.json:1"* ]]
  [[ "$output" == *"tombstone.name"* ]]
  [[ "$output" == *"hide_batch.py:8"* ]]
}

@test "a register row's own requester_name next to an erasure request fails" {
  # The register field (scripts/ops_intake/hide.py) -- this is the record a lane dumps when it quotes the register,
  # so it is the most likely way a requester's name reaches a committed evidence file.
  write_data lane/register.json '{"class":"privacy_erasure","requester_name":"Real Person"}'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"requester_name"* ]]
}

@test "a pretty-printed json object with the name field removed passes" {
  write_data lane/candidate.json '{
  "class": "privacy_erasure",
  "tombstone": {
    "creditCount_before": 9
  }
}'
  run_check
  [ "$status" -eq 0 ]
}

@test "a json-escaped class string cannot hide the name from the vocabulary test" {
  write_data lane/escaped.json '{"class":"privacy_\u0065rasure","name":"Real Person"}'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"data/lane/escaped.json:1"* ]]
  [[ "$output" == *"name"* ]]
}

@test "the same escaped-class file with the name removed passes" {
  write_data lane/escaped.json '{"class":"privacy_\u0065rasure","id":"7127c801"}'
  run_check
  [ "$status" -eq 0 ]
}

@test "a jsonl row with an escaped class string is caught too" {
  write_data lane/escaped.jsonl '{"class":"privacy_\u0065rasure","tombstone":{"name":"Real Person"}}'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"tombstone.name"* ]]
}

@test "a markdown table with a name column next to a hide request fails" {
  write_data lane/report.md '| id | name | register row |
|---|---|---|
| `7127c801` | Real Person | #34 GONE |'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"data/lane/report.md:1"* ]]
  [[ "$output" == *"markdown table header"* ]]
}

@test "the same report with the name column removed passes" {
  write_data lane/report.md '| id | register row |
|---|---|
| `7127c801` | #34 GONE |'
  run_check
  [ "$status" -eq 0 ]
}

@test "a name in a file with NO erasure vocabulary is not blocked" {
  write_data lane/ordinary.jsonl '{"id": "abc", "tombstone": {"name": "Real Person"}}'
  run_check
  [ "$status" -eq 0 ]
}

@test "a CI check name next to an unrelated 'erased' in prose is not a data subject's name" {
  # data/fleet-velocity-fable-v1/evidence.json: a QA-bot message body says "erased-recent-base-work" and the PR
  # runs carry `name: "PR Validation"`. Neither is an erasure-request record nor a person; an unanchored
  # vocabulary matched the `erase` SUBSTRING and turned the CI check name into a violation on every PR.
  write_data fleet/evidence.json '{
  "messages": [{"body": "erased-recent-base-work and re-verified"}],
  "prs": {"runs": [{"name": "PR Validation", "conclusion": "success"}]}
}'
  run_check
  [ "$status" -eq 0 ]
}

@test "the shipped tree is clean (ids only in data/ evidence)" {
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}
