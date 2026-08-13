#!/usr/bin/env bats
# Tests for deploy.sh Step 5a's cron SQLite import — specifically the
# last-moment store-only re-check.
#
# WHY THIS FILE EXISTS
# --------------------
# `detect-store-only-crons.py` reads the live store and halts on a durable cron
# cron-jobs.json does not declare. It runs ~50 lines of deploy work BEFORE the
# import, and never runs again. `saveCronStore` is delete-by-store_key +
# re-insert, so a cron created in that gap was silently DELETED — the guard had
# already passed. That is the 2026-07-16 ChartMogul loss (PR #702/#706)
# reachable through a window the guard cannot see.
#
# PR #821 fixed the equivalent window in the Step 6b heal
# (`cron_store_reimport`, covered in cron-store.bats). Step 6b cannot cover THIS
# one: a job deleted at Step 5a is absent from the store AND from the repo, so
# the post-restart diff is empty and reports convergence.
#
# The Step 5a import is an inline node program inside deploy.sh's POSTSYNC
# heredoc, which is why deploy.sh has no bats suite. Rather than assert on a
# grep, these tests EXTRACT the actual shipped program out of deploy.sh and run
# it against a stub SDK — so they exercise the bytes that deploy, not a copy
# that can drift.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY_SH="$HYDRA_REPO/scripts/deploy.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "ssh must not be called from these tests" >&2
exit 97
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
  # Hermeticity: this suite runs on node-8 as root in CI. Everything below is
  # pinned inside TEST_TMPDIR so the live /root/.openclaw-* stores are
  # unreachable even by accident.
  export OPENCLAW_STATE_DIR="$TEST_TMPDIR/state"
  mkdir -p "$OPENCLAW_STATE_DIR/cron"
  export LIVE_CRON="$OPENCLAW_STATE_DIR/cron/jobs.json"
  unset HYDRA_ALLOW_ORPHAN_CRON

  # The program under test, lifted verbatim out of deploy.sh.
  PROG="$TEST_TMPDIR/step5a.mjs"
  awk '/^      node --input-type=module -e .$/{f=1;next} f&&/^      . 2>&1\)/{exit} f{print}' \
    "$DEPLOY_SH" > "$PROG"
  [ -s "$PROG" ] || {
    echo "could not extract the Step 5a node program from deploy.sh — the markers moved"
    return 1
  }

  # Stub SDK: resolveCronStorePath mirrors the real resolver's use of
  # OPENCLAW_STATE_DIR; the store is a plain JSON file beside it.
  export CRON_SDK="$TEST_TMPDIR/cron-store-runtime.mjs"
  cat > "$CRON_SDK" <<'SDK'
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
export function resolveCronStorePath() {
  return process.env.OPENCLAW_STATE_DIR + "/cron/jobs.json";
}
export async function saveCronStore(target, store) {
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target + ".sqlite-sim", JSON.stringify(store));
}
export async function loadCronStore(target) {
  try { return JSON.parse(readFileSync(target + ".sqlite-sim", "utf8")); }
  catch (e) { return { jobs: [] }; }
}
SDK
  STORE="$LIVE_CRON.sqlite-sim"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
  unset HYDRA_ALLOW_ORPHAN_CRON
}

# The repo's declared set, written where deploy.sh puts it.
seed_repo() {
  printf '%s' '{"jobs":[
    {"id":"r1","name":"one","schedule":{"kind":"cron","expr":"0 1 * * *"}},
    {"id":"r2","name":"two","schedule":{"kind":"cron","expr":"0 2 * * *"}}
  ]}' > "$LIVE_CRON"
}
seed_store() { printf '%s' "$1" > "$STORE"; }
run_step5a() { run --separate-stderr node --input-type=module -e "$(cat "$PROG")"; }

@test "step5a: imports normally when the store holds only declared jobs" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  seed_store '{"jobs":[{"id":"r1"},{"id":"r2"}]}'

  run_step5a
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.persisted')" = "2" ]
}

@test "step5a: imports normally when the store is empty" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  seed_store '{"jobs":[]}'

  run_step5a
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.persisted')" = "2" ]
}

@test "step5a: REFUSES when a durable cron appeared after the store-only guard" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  # 'live-mrr' is the ChartMogul shape: a recurring job created directly on the
  # gateway, absent from cron-jobs.json.
  seed_store '{"jobs":[
    {"id":"r1"},
    {"id":"live-mrr","name":"Realtime MRR Movement","schedule":{"kind":"every","everyMs":300000}}
  ]}'
  before=$(cat "$STORE")

  run_step5a
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"STORE_ONLY_CRON_APPEARED"* ]]
  [[ "$stderr" == *"live-mrr"* ]]
  # The save never ran: the store is byte-identical, so nothing was destroyed.
  [ "$(cat "$STORE")" = "$before" ]
}

@test "step5a: an ephemeral one-shot in that window does NOT block the import" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  # qa-autoreview mints these constantly; they are not repo state and must not
  # halt a deploy (2026-06-30: counting them false-failed every deploy).
  seed_store '{"jobs":[
    {"id":"r1"},
    {"id":"qa-1","name":"qa-autoreview-pr-1","schedule":{"kind":"at"},"deleteAfterRun":true}
  ]}'

  run_step5a
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.persisted')" = "2" ]
}

@test "step5a: HYDRA_ALLOW_ORPHAN_CRON=1 drops the undeclared job deliberately" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  seed_store '{"jobs":[{"id":"r1"},{"id":"live-mrr","schedule":{"kind":"every","everyMs":300000}}]}'
  export HYDRA_ALLOW_ORPHAN_CRON=1

  run_step5a
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.persisted')" = "2" ]
  # The override means the operator asked for the drop, so it is gone.
  [ "$(jq -r '[.jobs[]|select(.id=="live-mrr")]|length' "$STORE")" = "0" ]
}

@test "step5a: the refusal is checked against a FRESH read, not the guard's snapshot" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  # The whole point: the guard's dump is stale by ~50 lines of deploy work. This
  # asserts the program reads the store itself rather than trusting anything
  # passed in — the store gains the job with no other input changing.
  seed_repo
  seed_store '{"jobs":[{"id":"r1"},{"id":"r2"}]}'
  run_step5a
  [ "$status" -eq 0 ]

  seed_store '{"jobs":[{"id":"r1"},{"id":"appeared-late","schedule":{"kind":"cron","expr":"* * * * *"}}]}'
  run_step5a
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"appeared-late"* ]]
}

# --- wiring: deploy.sh must act on rc 9 distinctly --------------------------

@test "deploy.sh handles import rc 9 before the generic failure path" {
  # A distinct arm matters: the generic message says the import FAILED, which
  # would send an operator hunting a broken import instead of a cron that needs
  # committing.
  block=$(awk '/IMPORT_RC == 9/{f=1} f{print} f&&/^  fi$/{exit}' "$DEPLOY_SH")
  [ -n "$block" ]
  [[ "$block" == *"REFUSED to overwrite"* ]]
  [[ "$block" == *"HYDRA_ALLOW_ORPHAN_CRON=1"* ]]
  # It must precede the catch-all rc!=0 arm, or the specific message never runs.
  rc9_line=$(grep -n 'IMPORT_RC == 9' "$DEPLOY_SH" | head -1 | cut -d: -f1)
  generic_line=$(grep -n 'IMPORT_RC != 0' "$DEPLOY_SH" | head -1 | cut -d: -f1)
  [ "$rc9_line" -lt "$generic_line" ]
}
