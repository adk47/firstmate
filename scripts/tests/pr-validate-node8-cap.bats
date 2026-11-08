#!/usr/bin/env bats
# pr-validate-node8-cap.bats — the node-8 concurrency cap must be a HOST flock, not a
# workflow-level group and not a bigger runner count.
#
# WHY (2026-10-27, Fable ruling on #1403). Five overlapping PR validations — every job
# `runs-on: [self-hosted, hydra]`, bats at `--jobs 8` — took node-8 to run queue 68,
# load 39, 344k ctx switches/s, 10 % idle and CPU-pressure PSI 52 % on a 24-core box
# that also runs the PRODUCTION openclaw gateway, and the timing-sensitive watchdog
# suites then failed on a DIFFERENT unrelated test each attempt (caroline-rag-index-
# watchdog, merge-landing-watchdog, agent-bridge-request), blocking five PRs.
#
# The cap that matches the resource is on the HOST: `scripts/bats-slot.sh` holds an
# exclusive flock so at most ONE suite runs per box. A constant concurrency group was
# explicitly rejected — GitHub has no host scope, it throws away the per-ref
# supersede-cancel, and its single pending slot silently drops a third PR's run.
#
# These cases pin the SHAPE that makes the cap real, and the behaviour of the slot itself
# is executed in scripts/tests/bats-slot.bats.

setup() {
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  wf="$repo_root/.github/workflows/pr-validate.yml"
  slot="$repo_root/scripts/bats-slot.sh"
}

@test "the bats step runs INSIDE the host slot" {
  run grep -E '^\s+scripts/bats-slot\.sh ' "$wf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--lock"* ]]
  [[ "$output" == *"--timeout"* ]]
  # The command under the slot must be the bats invocation, not something else.
  run grep -A1 -E '^\s+scripts/bats-slot\.sh ' "$wf"
  [[ "$output" == *"bats --jobs"* ]]
}

@test "the slot waits a bounded time, not forever" {
  run grep -E '^\s+scripts/bats-slot\.sh .*--timeout [0-9]+' "$wf"
  [ "$status" -eq 0 ]
  t=$(grep -oE '\-\-timeout [0-9]+' "$wf" | grep -oE '[0-9]+' | head -1)
  echo "timeout=$t"
  [ "$t" -ge 300 ]
  [ "$t" -le 3600 ]
}

@test "concurrency stays PER-REF with cancel-in-progress true (a constant group was rejected)" {
  # Read the BLOCK, not a fixed window. `grep -A2 '^concurrency:'` only ever saw the first two
  # lines, so the moment the group grew a comment explaining the event-aware discriminator the
  # assertion failed on prose rather than on the shape it exists to pin (QA #1813 r3).
  block="$(awk '/^concurrency:/{f=1;next} f&&/^[^ #]/{exit} f' "$wf" | grep -v '^[[:space:]]*#')"
  [ -n "$block" ]
  [[ "$block" == *'github.ref'* ]]
  [[ "$block" == *'cancel-in-progress: true'* ]]
  # No pool-wide constant group may creep back in.
  [[ "$block" != *'pr-validate-node8'* ]]
}

@test "the concurrency group is event-aware, so a metadata edit cannot cancel a code run" {
  # The discriminator is `github.event.changes.base`: present on a retarget, absent on a
  # metadata edit. A retarget must land in the `code` bucket, where it supersedes and is
  # superseded by ordinary code runs (QA #1813 r2).
  block="$(awk '/^concurrency:/{f=1;next} f&&/^[^ #]/{exit} f' "$wf" | grep -v '^[[:space:]]*#')"
  [[ "$block" == *"github.event.changes.base"* ]]
  [[ "$block" == *"'meta'"* ]]
  [[ "$block" == *"'code'"* ]]
}

@test "bats --jobs stays at 4 or below while this box also serves production" {
  run grep -E '^\s+bats --jobs [0-9]+' "$wf"
  [ "$status" -eq 0 ]
  jobs=$(grep -oE 'bats --jobs [0-9]+' "$wf" | grep -oE '[0-9]+' | head -1)
  echo "jobs=$jobs"
  [ "$jobs" -le 4 ]
}

@test "the slot script exists and is executable" {
  [ -x "$slot" ]
}

@test "the incident and the ruling are documented next to the setting" {
  run grep -c "2026-10-27" "$wf"
  [ "$output" -ge 1 ]
  run grep -ci "openclaw" "$wf"
  [ "$output" -ge 1 ]
  run grep -ci "flock" "$wf"
  [ "$output" -ge 1 ]
}
