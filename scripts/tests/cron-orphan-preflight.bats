#!/usr/bin/env bats
# MUS-3346: the pre-flight "Cron job orphan check" and deploy.sh's store-only
# guard both go through scripts/lib/dump-cron-store.sh + detect-store-only-crons.py.
# The old pre-flight read a dead jobs.json path and exit 0'd, so it could never
# fail. These tests pin: (1) the dump FAILS CLOSED, (2) a store-only durable cron
# turns the chain RED naming its id, (3) removing it turns it GREEN.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DUMP="$HYDRA_REPO/scripts/lib/dump-cron-store.sh"
DETECT="$HYDRA_REPO/scripts/lib/detect-store-only-crons.py"
WORKFLOW="$HYDRA_REPO/.github/workflows/pr-validate.yml"

setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/state"
  : > "$T/state/openclaw.sqlite"
  # Fake SDK: loadCronStore returns the JSON in $FAKE_STORE.
  cat > "$T/sdk.mjs" <<'JS'
import { readFileSync } from "node:fs";
export const resolveCronStorePath = () => "x";
export const loadCronStore = async () => JSON.parse(readFileSync(process.env.FAKE_STORE, "utf8"));
JS
  printf '%s\n' '{"jobs":[{"id":"repo-1","name":"declared","schedule":{"kind":"every","everyMs":3600000}}]}' > "$T/cron-jobs.json"
  printf '%s\n' '{"jobs":[{"id":"repo-1","name":"declared","schedule":{"kind":"every","everyMs":3600000}}]}' > "$T/store.json"
  export OPENCLAW_STATE_DIR="$T" CRON_SDK="$T/sdk.mjs" FAKE_STORE="$T/store.json"
  unset HYDRA_ALLOW_ORPHAN_CRON
}
teardown() { rm -rf "$T"; }

chain() { "$DUMP" "$T/dump.json" && python3 "$DETECT" "$T/cron-jobs.json" "$T/dump.json"; }

@test "dump fails closed when the SQLite store is missing" {
  rm "$T/state/openclaw.sqlite"
  run -1 "$DUMP" "$T/dump.json"
  [[ "$output" == *"live SQLite store not found"* ]]
}

@test "dump fails closed when the SDK is missing" {
  CRON_SDK="$T/nope.mjs" run -1 "$DUMP" "$T/dump.json"
  [[ "$output" == *"cron-store SDK not found"* ]]
}

@test "GREEN: store matches the repo" {
  run -0 chain
}

@test "RED: a durable store-only cron fails the chain and names its id" {
  printf '%s\n' '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":1}},{"id":"throwaway-orphan-3346","name":"x","schedule":{"kind":"every","everyMs":60000}}]}' > "$T/store.json"
  run -3 chain
  [[ "$output" == *"throwaway-orphan-3346"* ]]
}

@test "GREEN again: an ephemeral one-shot store-only cron is exempt" {
  printf '%s\n' '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":1}},{"id":"oneshot","deleteAfterRun":true,"schedule":{"kind":"at","at":"2030-01-01T00:00:00Z"}}]}' > "$T/store.json"
  run -0 chain
}

# The workflow step is the gate under test: tests 1-5 drive the helpers directly,
# so these pin that the STEP still wires them and has no skip branch.
# Negations use `run !` / `if …; then false; fi`: a bare `! grep` is exempt from
# bats' set -e and could not fail.
step_body() {
  sed -n '/- name: Cron job orphan check/,/- name: Plugin env-var preflight/p' "$WORKFLOW" | grep -v '^[[:space:]]*#'
}

@test "pr-validate step runs the dump helper, then the detector on cron-jobs.json" {
  [ -n "$(step_body)" ]
  step_body | grep -q 'scripts/lib/dump-cron-store.sh "\$STORE_DUMP"'
  step_body | grep -q 'python3 scripts/lib/detect-store-only-crons.py cron-jobs.json "\$STORE_DUMP"'
}

@test "pr-validate step has no dead jobs.json read and no skip/exit 0 branch" {
  [ -n "$(step_body)" ]
  if step_body | grep -q 'cron/jobs.json'; then false; fi
  if step_body | grep -qi 'skipping'; then false; fi
  if step_body | grep -qE 'exit 0'; then false; fi
}

@test "deploy.sh store-only guard still reads the store through the dump helper" {
  grep -q 'scripts/lib/dump-cron-store.sh" "\$STORE_DUMP"' "$HYDRA_REPO/scripts/deploy.sh"
  grep -q 'detect-store-only-crons.py" "\$HYDRA_ROOT/cron-jobs.json" "\$STORE_DUMP"' "$HYDRA_REPO/scripts/deploy.sh"
}
