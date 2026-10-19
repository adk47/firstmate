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

@test "step5a: a runtime-DECLARED cron in that window does NOT block the import" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  # openclaw >= 2026.8.2 declares these from config at boot and regenerates
  # their ids every boot, so they can never be committed to cron-jobs.json.
  # On 2026-09-10 they blocked deploy pass 2 outright (11 unexpected, 0 missing).
  seed_store '{"jobs":[
    {"id":"r1"},
    {"id":"boot-uuid-a","name":"heartbeat-clio","declarationKey":"heartbeat:clio","payload":{"kind":"heartbeat"},"schedule":{"kind":"every","everyMs":1800000}}
  ]}'

  run_step5a
  [ "$status" -eq 0 ]
}

@test "step5a: a BLANK declarationKey still blocks (fail closed, not excluded)" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  seed_store '{"jobs":[
    {"id":"r1"},
    {"id":"ambiguous","name":"blank-key","declarationKey":"","schedule":{"kind":"every","everyMs":3600000}}
  ]}'

  run_step5a
  [ "$status" -eq 9 ]
}

# QA finding (PR #924): `openclaw cron add --declaration-key custom:billing` is
# a real operator action, so a custom key must block exactly like no key at all.
# QA finding round 2 (PR #924): heartbeat: is not a reserved namespace, so a
# forged one is operator work and must block exactly like a custom key.
@test "step5a: a FORGED heartbeat: key with an operator payload still blocks" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  seed_store '{"jobs":[
    {"id":"r1"},
    {"id":"human","name":"billing-hb","declarationKey":"heartbeat:billing","payload":{"kind":"agentTurn","message":"run billing"},"schedule":{"kind":"every","everyMs":3600000}}
  ]}'

  run_step5a
  [ "$status" -eq 9 ]
}

@test "step5a: a CUSTOM declarationKey still blocks (operator work, not a runtime declaration)" {

  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  seed_store '{"jobs":[
    {"id":"r1"},
    {"id":"human","name":"billing-cron","declarationKey":"custom:billing","schedule":{"kind":"every","everyMs":3600000}}
  ]}'

  run_step5a
  [ "$status" -eq 9 ]
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

# --- the persisted-count check must read only the JSON result line ----------
#
# deploy.sh captures the import as IMPORT_OUT=$(node ... 2>&1), so stdout AND
# stderr land in one blob. On 2026-10-17 06:33Z (run 39010306853) the runtime
# logged "[sqlite/transaction] slow SQLite transaction hold" to stderr ahead of
# the {"target":...,"persisted":N} line; piping the whole blob to jq made a
# SUCCESSFUL import look unparseable and failed the deploy. These tests run the
# shipped node program with deploy's exact 2>&1 capture, then run the shipped
# verification block (lifted verbatim out of deploy.sh) over that output.

# Lift the post-import verification block (EXPECTED_JOBS .. the success log).
extract_verify_block() {
  VERIFY="$TEST_TMPDIR/step5a-verify.sh"
  awk '/^  EXPECTED_JOBS=\$\(jq /{f=1} f{print} f&&/^  log "  Imported /{exit}' \
    "$DEPLOY_SH" > "$VERIFY"
  grep -q 'PERSISTED_JOBS' "$VERIFY" || {
    echo "could not extract the Step 5a verification block from deploy.sh — the markers moved"
    return 1
  }
}

# Run the verification block under deploy's POSTSYNC shell options, with
# deploy's fail/log semantics (fail exits non-zero; Slack is out of scope).
run_verify() {
  export IMPORT_OUT="$1"
  export HYDRA_ROOT="$TEST_TMPDIR/repo"
  export VERIFY
  run bash -c '
    set -euo pipefail
    log() { echo "LOG: $*"; }
    fail() { log "FATAL: $*"; exit 1; }
    source "$VERIFY"
    echo "VERIFY_OK persisted=$PERSISTED_JOBS"
  '
}

seed_hydra_root() {
  mkdir -p "$TEST_TMPDIR/repo"
  cp "$LIVE_CRON" "$TEST_TMPDIR/repo/cron-jobs.json"
}

# Make the stub SDK emit a stderr warning during the save, the way the real
# runtime did on 2026-10-17, before the program prints its JSON result.
warn_on_save() {
  cat > "$CRON_SDK" <<'SDK'
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
export function resolveCronStorePath() {
  return process.env.OPENCLAW_STATE_DIR + "/cron/jobs.json";
}
export async function saveCronStore(target, store) {
  console.error("[sqlite/transaction] slow SQLite transaction hold: 1834ms (cron_jobs)");
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target + ".sqlite-sim", JSON.stringify(store));
}
export async function loadCronStore(target) {
  try { return JSON.parse(readFileSync(target + ".sqlite-sim", "utf8")); }
  catch (e) { return { jobs: [] }; }
}
SDK
}

@test "step5a verify: a stderr warning before the JSON result does NOT fail a successful import" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  seed_hydra_root
  seed_store '{"jobs":[]}'
  warn_on_save
  extract_verify_block

  # deploy.sh's exact capture: stdout+stderr in one variable.
  out=$(node --input-type=module -e "$(cat "$PROG")" 2>&1)
  # Precondition: the reproduced blob really is warning-then-JSON, which the
  # pre-fix whole-blob `jq .persisted` could not parse.
  [[ "$(printf '%s\n' "$out" | head -n 1)" == "[sqlite/transaction]"* ]]
  ! printf '%s' "$out" | jq -r '.persisted' >/dev/null 2>&1

  run_verify "$out"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERIFY_OK persisted=2"* ]]
  [[ "$output" == *"Imported 2 cron jobs"* ]]
}

@test "step5a verify: a clean JSON-only import still passes" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  seed_repo
  seed_hydra_root
  seed_store '{"jobs":[]}'
  extract_verify_block

  out=$(node --input-type=module -e "$(cat "$PROG")" 2>&1)
  run_verify "$out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERIFY_OK persisted=2"* ]]
}

@test "step5a verify: FAILS CLOSED when the output has no JSON result line" {
  extract_verify_block
  seed_repo
  seed_hydra_root
  run_verify "[sqlite/transaction] slow SQLite transaction hold: 1834ms (cron_jobs)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL: cron SQLite import: store persisted <unparseable> jobs, expected 2"* ]]
  [[ "$output" != *"VERIFY_OK"* ]]
}

@test "step5a verify: FAILS CLOSED when the result line reports the wrong count, even behind a warning" {
  extract_verify_block
  seed_repo
  seed_hydra_root
  run_verify '[sqlite/transaction] slow SQLite transaction hold: 1834ms (cron_jobs)
{"target":"/x/cron/jobs.json","persisted":0}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL: cron SQLite import: store persisted 0 jobs, expected 2"* ]]
}

@test "step5a verify: FAILS CLOSED on empty import output" {
  extract_verify_block
  seed_repo
  seed_hydra_root
  run_verify ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"store persisted <unparseable> jobs, expected 2"* ]]
}

# D2 (MUS-13135): the POSTSYNC heredoc is a CHILD bash under `set -euo
# pipefail`. `fail` reads $REPORT_ONLY and `notify_slack` reads $SLACK_WEBHOOK;
# if the parent's export line omits them, the child prints FATAL and then dies
# on "REPORT_ONLY: unbound variable" BEFORE it can page Slack (2026-10-17).
@test "POSTSYNC child: a fail() reaches notify_slack, not an unbound REPORT_ONLY" {
  # Mirror the parent: shipped bytes of the vars, the functions and the export lines.
  fn() { grep -E "^$1\(\) \{" "$DEPLOY_SH"; }
  export_line=$(grep -E '^export HYDRA_ROOT TARGET' "$DEPLOY_SH")
  [ -n "$export_line" ]
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
echo "CURL_CALLED $*" >> "$TEST_TMPDIR/curl.log"
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"

  parent="$TEST_TMPDIR/parent.sh"
  {
    echo 'HYDRA_ROOT=/x TARGET=all DEPLOY_PATH=/x HYDRA_LOCAL=/x REPORT_ONLY=0'
    echo 'SLACK_WEBHOOK=https://hooks.invalid/x'
    fn log; fn fail; fn notify_slack; fn needs_target
    echo "$export_line"
    echo 'export -f fail log notify_slack needs_target'
    echo "bash <<'CHILD'"
    echo 'set -euo pipefail'
    echo 'fail "cron SQLite import: store persisted <unparseable> jobs, expected 40"'
    echo 'CHILD'
  } > "$parent"
  # notify_slack is multi-line; the grep above only lifts its first line.
  awk '/^notify_slack\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DEPLOY_SH" > "$TEST_TMPDIR/ns.sh"
  sed -i.bak '/^notify_slack() {/d' "$parent"
  sed -i.bak "/^needs_target/r $TEST_TMPDIR/ns.sh" "$parent"

  run bash "$parent"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: cron SQLite import"* ]]
  [[ "$output" != *"unbound variable"* ]]
  grep -q CURL_CALLED "$TEST_TMPDIR/curl.log"
}
