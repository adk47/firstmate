#!/usr/bin/env bats
# Tests for scripts/lib/cron-store.sh — the durable-cron accounting shared by
# smoke-test.sh's cron count check and deploy.sh's Step 6b convergence heal.
#
# The counting rules encode two real incidents:
#   - 2026-06-30: counting the QA bot's ephemeral one-shots false-failed every
#     deploy that overlapped a dispatch (repo=26 vs loaded=28).
#   - 2026-08-11: the pre-restart import was clobbered by the running gateway
#     and the deploy rolled back (repo=33 vs loaded=32) — the case Step 6b now
#     heals. 17 of those 32 were enabled:false, which is why "disabled crons
#     are counted" is a load-bearing assertion, not a detail.
#
# PATH-shadows ssh so an accidental remote call fails loudly
# (see memory/feedback_bats_must_stub_openclaw.md).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/cron-store.sh"

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
  # Hermeticity: this suite runs on node-8 in CI, as root. Pin the state root
  # for EVERY test — not just the reimport ones — so no code path can reach the
  # live /root/.openclaw-{main,edge} cron stores even if a stub is forgotten.
  export CRON_STORE_STATE_ROOT="$TEST_TMPDIR/state/.openclaw"
  # Never inherit the operator override from the environment: a test that meant
  # to assert the refusal would silently assert the drop instead.
  unset HYDRA_ALLOW_ORPHAN_CRON
  # shellcheck source=../lib/cron-store.sh
  source "$LIB"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
  unset HYDRA_ALLOW_ORPHAN_CRON
}

# Write a fake `openclaw` that prints $1 on stdout, optional noise on stderr,
# and exits $2. Records its argv so a test can assert the flags we rely on.
# Plain `if` (not `[ ... ] && ...`): a trailing false test would abort the
# enclosing bats body under errexit.
stub_openclaw() {
  local payload="$1" rc="${2:-0}" stderr_noise="${3:-}"
  local stub="$TEST_TMPDIR/bin/openclaw"
  {
    echo '#!/bin/bash'
    printf 'printf "%%s\\n" "$*" > %s/openclaw.argv\n' "$TEST_TMPDIR"
    if [ -n "$stderr_noise" ]; then
      printf 'cat >&2 <<%s\n%s\nNOISE\n' "'NOISE'" "$stderr_noise"
    fi
    printf 'cat <<%s\n%s\nPAYLOAD\n' "'PAYLOAD'" "$payload"
    printf 'exit %s\n' "$rc"
  } > "$stub"
  chmod +x "$stub"
  export OPENCLAW_BIN="$stub"
}

# --- cron_store_durable_count_from_json ------------------------------------

@test "counts durable jobs and excludes ephemeral one-shots" {
  json='{"jobs":[
    {"name":"a","schedule":{"kind":"cron"}},
    {"name":"b","schedule":{"kind":"every"}},
    {"name":"qa-autoreview-pr-1","schedule":{"kind":"at"},"deleteAfterRun":true},
    {"name":"qa-autoreview-pr-2","schedule":{"kind":"at"},"deleteAfterRun":true}
  ]}'
  run cron_store_durable_count_from_json "$json"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "counts DISABLED crons (cron list --all returns them; do not narrow to enabled-only)" {
  json='{"jobs":[
    {"name":"on","enabled":true,"schedule":{"kind":"cron"}},
    {"name":"off1","enabled":false,"schedule":{"kind":"cron"}},
    {"name":"off2","enabled":false,"schedule":{"kind":"cron"}}
  ]}'
  run cron_store_durable_count_from_json "$json"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "an 'at' job WITHOUT deleteAfterRun is durable and counted" {
  json='{"jobs":[
    {"name":"one-time-but-durable","schedule":{"kind":"at"}},
    {"name":"ephemeral","schedule":{"kind":"at"},"deleteAfterRun":true}
  ]}'
  run cron_store_durable_count_from_json "$json"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a deleteAfterRun job on a RECURRING schedule is still counted" {
  json='{"jobs":[{"name":"recurring","schedule":{"kind":"cron"},"deleteAfterRun":true}]}'
  run cron_store_durable_count_from_json "$json"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "a PAGINATED response is UNKNOWN (rc 2), never .total" {
  # .total is the ALL-ROWS count and includes the ephemerals this filter exists
  # to exclude, so substituting it over-reports durables and would make Step 6b
  # 'heal' a store that was never wrong. openclaw 2026.7.1's `cron list` has no
  # paging flag, so the unseen rows cannot be fetched — UNKNOWN is the only
  # honest answer.
  json='{"hasMore":true,"total":41,"jobs":[
    {"name":"a","schedule":{"kind":"cron"}},
    {"name":"eph","schedule":{"kind":"at"},"deleteAfterRun":true}
  ]}'
  run cron_store_durable_count_from_json "$json"
  [ "$status" -eq 2 ]
  [ "$output" != "41" ]
  [ "$output" != "40" ]
}

@test "hasMore:false uses the durable filter, not .total" {
  json='{"hasMore":false,"total":3,"jobs":[
    {"name":"a","schedule":{"kind":"cron"}},
    {"name":"b","schedule":{"kind":"cron"}},
    {"name":"eph","schedule":{"kind":"at"},"deleteAfterRun":true}
  ]}'
  run cron_store_durable_count_from_json "$json"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "a paginated gateway response propagates rc 2 through the gateway wrapper" {
  stub_openclaw '{"hasMore":true,"total":99,"jobs":[{"name":"a","schedule":{"kind":"cron"}}]}'
  run cron_store_gateway_durable_count main
  [ "$status" -eq 2 ]
}

@test "zero durable jobs is a valid count, not an error" {
  json='{"jobs":[]}'
  run cron_store_durable_count_from_json "$json"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "unparseable JSON returns non-zero (unknown is NOT zero)" {
  run cron_store_durable_count_from_json 'Config warnings: not json at all'
  [ "$status" -ne 0 ]
  [ "$output" != "0" ]
}

@test "empty input returns non-zero" {
  run cron_store_durable_count_from_json ""
  [ "$status" -ne 0 ]
}

@test "JSON without a .jobs array returns non-zero rather than a bogus count" {
  run cron_store_durable_count_from_json '{"unexpected":"shape"}'
  [ "$status" -ne 0 ]
}

# --- cron_store_gateway_durable_count --------------------------------------

@test "gateway count parses the CLI payload and passes --all" {
  stub_openclaw '{"jobs":[
    {"name":"a","schedule":{"kind":"cron"}},
    {"name":"b","enabled":false,"schedule":{"kind":"cron"}},
    {"name":"eph","schedule":{"kind":"at"},"deleteAfterRun":true}
  ]}'
  run cron_store_gateway_durable_count main
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  run cat "$TEST_TMPDIR/openclaw.argv"
  [[ "$output" == *"--all"* ]]
  [[ "$output" == *"--profile main"* ]]
}

@test "gateway count ignores 'Config warnings:' stderr noise" {
  stub_openclaw '{"jobs":[{"name":"a","schedule":{"kind":"cron"}}]}' 0 'Config warnings:
- plugins.entries.openai
'
  run cron_store_gateway_durable_count main
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "gateway count returns non-zero when the CLI exits non-zero" {
  stub_openclaw '{"jobs":[]}' 1
  run cron_store_gateway_durable_count main
  [ "$status" -ne 0 ]
}

@test "gateway count returns non-zero when the CLI prints garbage" {
  stub_openclaw 'gateway not running'
  run cron_store_gateway_durable_count main
  [ "$status" -ne 0 ]
}

# --- cron_store_repo_count --------------------------------------------------

@test "repo count is the plain job length" {
  printf '%s' '{"jobs":[{"id":"1"},{"id":"2"},{"id":"3"}]}' > "$TEST_TMPDIR/cron-jobs.json"
  run cron_store_repo_count "$TEST_TMPDIR/cron-jobs.json"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "repo count returns non-zero for a missing file" {
  run cron_store_repo_count "$TEST_TMPDIR/does-not-exist.json"
  [ "$status" -ne 0 ]
}

@test "repo count returns non-zero for malformed JSON" {
  printf '%s' '{"jobs":[' > "$TEST_TMPDIR/bad.json"
  run cron_store_repo_count "$TEST_TMPDIR/bad.json"
  [ "$status" -ne 0 ]
}

# --- cron_store_converge (the Step 6b decision) -----------------------------
#
# deploy.sh has no bats harness, so the convergence decision lives in the lib
# precisely so these branches are reachable. Each test drives the real
# cron_store_converge with the identity/reimport/restart seams stubbed, and
# asserts both the exit code deploy.sh switches on and whether a restart
# actually fired.

# Three durable jobs. Gateway payloads below are built from the same shapes so
# the identity projection is exercised for real, not hand-written.
_jobs_full() {
  printf '%s' '{"jobs":[
    {"id":"j1","agentId":"ops","name":"one","enabled":true,"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}},
    {"id":"j2","agentId":"ops","name":"two","enabled":false,"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"}},
    {"id":"j3","agentId":"ops","name":"three","enabled":true,"schedule":{"kind":"cron","expr":"15 */4 * * *","tz":"UTC"}}
  ]}'
}
# The 2026-08-11 shape: the added job is gone, plus live ephemerals.
_jobs_clobbered() {
  printf '%s' '{"jobs":[
    {"id":"j1","agentId":"ops","name":"one","enabled":true,"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}},
    {"id":"j2","agentId":"ops","name":"two","enabled":false,"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"}},
    {"id":"qa-1","name":"qa-autoreview-pr-1","schedule":{"kind":"at"},"deleteAfterRun":true}
  ]}'
}
# SAME COUNT, different job: j3 replaced by j4.
_jobs_swapped() {
  printf '%s' '{"jobs":[
    {"id":"j1","agentId":"ops","name":"one","enabled":true,"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}},
    {"id":"j2","agentId":"ops","name":"two","enabled":false,"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"}},
    {"id":"j4","agentId":"ops","name":"four","enabled":true,"schedule":{"kind":"cron","expr":"0 4 * * *","tz":"UTC"}}
  ]}'
}
# SAME COUNT, same ids: j3 still on its OLD schedule.
_jobs_old_schedule() {
  printf '%s' '{"jobs":[
    {"id":"j1","agentId":"ops","name":"one","enabled":true,"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}},
    {"id":"j2","agentId":"ops","name":"two","enabled":false,"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"}},
    {"id":"j3","agentId":"ops","name":"three","enabled":true,"schedule":{"kind":"cron","expr":"0 6 * * *","tz":"UTC"}}
  ]}'
}
# SAME COUNT, same ids and schedules: j2 silently re-enabled.
_jobs_enable_flipped() {
  printf '%s' '{"jobs":[
    {"id":"j1","agentId":"ops","name":"one","enabled":true,"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}},
    {"id":"j2","agentId":"ops","name":"two","enabled":true,"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"}},
    {"id":"j3","agentId":"ops","name":"three","enabled":true,"schedule":{"kind":"cron","expr":"15 */4 * * *","tz":"UTC"}}
  ]}'
}

# `every`-kind jobs: their schedule lives in everyMs/anchorMs, NOT expr.
_jobs_every() {
  printf '%s' '{"jobs":[
    {"id":"e1","agentId":"cmo","name":"hourly","enabled":true,"schedule":{"kind":"every","everyMs":3600000,"anchorMs":1780665204552}},
    {"id":"e2","agentId":"cmo","name":"daily","enabled":true,"schedule":{"kind":"every","everyMs":86400000,"anchorMs":1780672931064}}
  ]}'
}
_jobs_every_interval_changed() {
  printf '%s' '{"jobs":[
    {"id":"e1","agentId":"cmo","name":"hourly","enabled":true,"schedule":{"kind":"every","everyMs":900000,"anchorMs":1780665204552}},
    {"id":"e2","agentId":"cmo","name":"daily","enabled":true,"schedule":{"kind":"every","everyMs":86400000,"anchorMs":1780672931064}}
  ]}'
}
_jobs_every_anchor_changed() {
  printf '%s' '{"jobs":[
    {"id":"e1","agentId":"cmo","name":"hourly","enabled":true,"schedule":{"kind":"every","everyMs":3600000,"anchorMs":1780665204552}},
    {"id":"e2","agentId":"cmo","name":"daily","enabled":true,"schedule":{"kind":"every","everyMs":86400000,"anchorMs":1999999999999}}
  ]}'
}
# What the GATEWAY returns for _jobs_full: identical, plus its injected default.
_jobs_full_with_stagger() {
  printf '%s' '{"jobs":[
    {"id":"j1","agentId":"ops","name":"one","enabled":true,"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC","staggerMs":300000}},
    {"id":"j2","agentId":"ops","name":"two","enabled":false,"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC","staggerMs":300000}},
    {"id":"j3","agentId":"ops","name":"three","enabled":true,"schedule":{"kind":"cron","expr":"15 */4 * * *","tz":"UTC","staggerMs":300000}}
  ]}'
}

setup_converge() {
  _jobs_full > "$TEST_TMPDIR/cron-jobs.json"
  REPO_JSON="$TEST_TMPDIR/cron-jobs.json"
  RESTART_LOG="$TEST_TMPDIR/restarts"
  : > "$RESTART_LOG"
  CRON_STORE_LOG_FN=_converge_log
  CRON_STORE_REIMPORT_FN=_reimport_ok
  CRON_STORE_STOP_FN=_stop_ok
  CRON_STORE_START_FN=_start_ok
  export RESTART_LOG
}
_converge_log() { :; }
# The heal now runs with the gateway STOPPED, so the seams are stop/start.
# LIFECYCLE_LOG records the ORDER, which is the property that matters: the
# import must happen between a stop and a start, never alongside a live writer.
_stop_ok()    { printf 'stop %s\n'  "$1" >> "$RESTART_LOG"; return 0; }
_stop_fail()  { printf 'stopfail\n'      >> "$RESTART_LOG"; return 1; }
_start_ok()   { printf 'start %s\n' "$1" >> "$RESTART_LOG"; return 0; }
_start_fail() { printf 'startfail\n'     >> "$RESTART_LOG"; return 1; }
# grep -c prints 0 AND exits 1 when nothing matches, so a bare `|| echo 0`
# emits "0\n0". Capture, then default.
_restart_count() { local n; n=$(grep -c '^start ' "$RESTART_LOG" 2>/dev/null) || n=0; printf '%s' "$n"; }
_lifecycle() { tr '\n' ' ' < "$RESTART_LOG"; }
_reimport_ok()    { printf 'import\n' >> "$RESTART_LOG"; printf '3'; }
_reimport_short() { printf '2'; }
_reimport_fail()  { return 1; }
_reimport_boom()  { echo "reimport must not run" >&2; return 1; }

# Identity seams: emit the projection of a given gateway payload.
_jobset_full()          { cron_store_jobset_from_json "$(_jobs_full)"; }
_jobset_clobbered()     { cron_store_jobset_from_json "$(_jobs_clobbered)"; }
_jobset_swapped()       { cron_store_jobset_from_json "$(_jobs_swapped)"; }
_jobset_old_schedule()  { cron_store_jobset_from_json "$(_jobs_old_schedule)"; }
_jobset_enable_flipped(){ cron_store_jobset_from_json "$(_jobs_enable_flipped)"; }
# Drifted before the restart, correct after it.
_jobset_heals() {
  if [ -s "$RESTART_LOG" ]; then _jobset_full; else _jobset_clobbered; fi
}

@test "converge: no drift returns 0, imports nothing, restarts nothing" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_full
  CRON_STORE_REIMPORT_FN=_reimport_boom

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ "$(_restart_count)" = "0" ]
}

@test "converge: the 33-vs-32 clobber heals and returns 1" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_heals

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 1 ]
  [ "$(_restart_count)" = "1" ]
}

@test "converge: SAME-COUNT swap (j3 replaced by j4) is detected, not passed" {
  # The count-only gate this replaced returned 3 == 3 and shipped a gateway
  # missing j3 entirely. It now REFUSES rather than heals: j4 is a durable cron
  # the repo does not declare, and the re-import would delete it (rc 10).
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_swapped
  CRON_STORE_REIMPORT_FN=_reimport_boom

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 10 ]
  [ "$(_restart_count)" = "0" ]
}

@test "converge: a swap with NO undeclared leftover still heals normally" {
  # j3 simply missing (the pure clobber shape) must still take the heal path,
  # so the rc-10 refusal cannot become a blanket "never heal".
  setup_converge
  _jobset_heals_missing() {
    if [ -s "$RESTART_LOG" ]; then _jobset_full; else _jobset_clobbered; fi
  }
  CRON_STORE_JOBSET_FN=_jobset_heals_missing

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 1 ]
  [ "$(_restart_count)" = "1" ]
}

@test "converge: SAME-COUNT schedule change is detected, not passed" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_old_schedule

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 9 ]
}

@test "converge: SAME-COUNT enabled flip is detected, not passed" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_enable_flipped

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 9 ]
}

@test "converge: heal restarts EXACTLY once, never loops" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_clobbered   # never converges

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 9 ]
  [ "$(_restart_count)" = "1" ]
}

@test "converge: unreadable repo file returns 2" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_full
  run cron_store_converge main "$TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
}

@test "converge: unreadable gateway identity returns 3 and never re-imports" {
  setup_converge
  _jobset_unknown() { return 1; }
  CRON_STORE_JOBSET_FN=_jobset_unknown
  CRON_STORE_REIMPORT_FN=_reimport_boom

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 3 ]
  [ "$(_restart_count)" = "0" ]
}

@test "converge: a PAGINATED identity returns 4, distinct from unparseable" {
  setup_converge
  _jobset_paginated() { return 2; }
  CRON_STORE_JOBSET_FN=_jobset_paginated
  CRON_STORE_REIMPORT_FN=_reimport_boom

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 4 ]
  [ "$(_restart_count)" = "0" ]
}

@test "converge: a failed re-import returns 5 and STILL brings the gateway back" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_clobbered
  CRON_STORE_REIMPORT_FN=_reimport_fail

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 5 ]
  # The import failed, but the gateway was stopped for it — leaving the fleet
  # down would be far worse than the failed heal.
  [ "$(_restart_count)" = "1" ]
  # _reimport_fail logs nothing, so the trace is stop -> start: the point is
  # that the start still happened.
  [ "$(_lifecycle)" = "stop main start main " ]
}

@test "converge: a wrong-count re-import returns 6 and STILL brings the gateway back" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_clobbered
  CRON_STORE_REIMPORT_FN=_reimport_short   # persisted 2, repo declares 3

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 6 ]
  [ "$(_restart_count)" = "1" ]
}

@test "converge: a failed START returns 14 — the fleet is down and it says so" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_clobbered
  CRON_STORE_START_FN=_start_fail

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 14 ]
}

@test "converge: missing lifecycle seams return 7 rather than importing unprotected" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_clobbered
  CRON_STORE_STOP_FN=""
  CRON_STORE_START_FN=""

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 7 ]
}

@test "converge: an unreadable identity after the heal returns 8, not a false pass" {
  setup_converge
  _jobset_then_blind() {
    if [ -s "$RESTART_LOG" ]; then return 1; fi
    _jobset_clobbered
  }
  CRON_STORE_JOBSET_FN=_jobset_then_blind

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 8 ]
  [ "$(_restart_count)" = "1" ]
}

@test "converge: the failure diff names the job that actually differs" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_swapped
  cron_store_converge main "$REPO_JSON" || true
  [[ "$CRON_STORE_DIFF" == *'"missing":["j3"]'* ]]
  [[ "$CRON_STORE_DIFF" == *'"unexpected":["j4"]'* ]]
}

@test "converge: the diff names a changed job when ids match but content does not" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_old_schedule
  cron_store_converge main "$REPO_JSON" || true
  [[ "$CRON_STORE_DIFF" == *'"changed":["j3"]'* ]]
}

@test "deploy.sh handles every cron_store_converge exit code, plus a catch-all" {
  # The rc contract is the seam between the tested lib and the untestable
  # deploy.sh. Renumbering an rc in the lib without following it here would
  # silently route a real failure into the wrong message — or, before the
  # catch-all existed, into no arm at all. Slice ONLY the Step 6b case block so
  # this can't be satisfied by identical arm labels elsewhere in deploy.sh.
  block=$(awk '/cron_store_converge main/{f=1} f{print} f&&/^[[:space:]]*esac[[:space:]]*$/{exit}' \
            "$HYDRA_REPO/scripts/deploy.sh")
  [ -n "$block" ]
  for rc in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    echo "$block" | grep -qE "^[[:space:]]*${rc}\)" || {
      echo "deploy.sh Step 6b has no case arm for cron_store_converge rc=$rc"
      return 1
    }
  done
  # An unrecognized status must not fall through silently.
  echo "$block" | grep -qE '^[[:space:]]*\*\)'
}

# --- cron_store_reimport, for real ------------------------------------------
#
# Drives the ACTUAL function — path construction, install, the node invocation,
# the JSON parse and the count check — against a stubbed openclaw SDK module.
# CRON_STORE_STATE_ROOT keeps it off the live /root/.openclaw-* dirs; the bats
# job runs on node-8 itself, so a hard-coded prod path here would clobber fleet
# state on every CI run.

stub_sdk() {
  local behavior="${1:-ok}"
  local root="$TEST_TMPDIR/npm-root"
  mkdir -p "$root/openclaw/dist/plugin-sdk"
  if [ "$behavior" = "missing" ]; then
    rm -rf "$root/openclaw/dist/plugin-sdk"
  else
    cat > "$root/openclaw/dist/plugin-sdk/cron-store-runtime.js" <<SDK
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname } from "node:path";
// Mirrors the real resolver: the store_key is derived from OPENCLAW_STATE_DIR.
export function resolveCronStorePath() {
  return process.env.OPENCLAW_STATE_DIR + "/cron/jobs.json";
}
export async function saveCronStore(target, store) {
  if ("$behavior" === "savefail") throw new Error("save exploded");
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target + ".sqlite-sim", JSON.stringify(store));
}
export async function loadCronStore(target) {
  if ("$behavior" === "loadfail") throw new Error("transient store read failure");
  if ("$behavior" === "shortread") return { jobs: [{ id: "j1" }] };  // declared, so only the COUNT is short
  let cur = { jobs: [] };
  try { cur = JSON.parse(readFileSync(target + ".sqlite-sim", "utf8")); } catch (e) {}
  if ("$behavior" === "concurrent-add" && !existsSync(process.env.OPENCLAW_STATE_DIR + "/.add-seen")) {
    // Simulates an operator adding a recurring cron AFTER converge took its
    // snapshot but BEFORE the save — the window the in-save re-check closes.
    // ONE-SHOT: a real concurrent add happens once, so injecting it into the
    // post-save read-back too would just inflate the persisted count.
    writeFileSync(process.env.OPENCLAW_STATE_DIR + "/.add-seen", "1");
    cur.jobs = (cur.jobs || []).concat([
      { id: "added-during-drain", name: "live add", schedule: { kind: "cron", expr: "*/5 * * * *" } },
    ]);
  }
  return cur;
}
SDK
  fi
  cat > "$TEST_TMPDIR/bin/npm" <<NPMSTUB
#!/bin/bash
[ "\$1" = "root" ] && [ "\$2" = "-g" ] || exit 64
$([ "$behavior" = "npmfail" ] && echo 'exit 1')
printf '%s\n' "$root"
NPMSTUB
  chmod +x "$TEST_TMPDIR/bin/npm"
  export CRON_STORE_STATE_ROOT="$TEST_TMPDIR/state/.openclaw"
  # Never inherit the operator override from the environment: a test that meant
  # to assert the refusal would silently assert the drop instead.
  unset HYDRA_ALLOW_ORPHAN_CRON
}

@test "reimport: writes the profile's store_key and reports the persisted count" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk ok

  # --separate-stderr: the function warns on stderr (e.g. an unreadable live
  # store) and bats' plain `run` would fold that into $output.
  run --separate-stderr cron_store_reimport main "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
  # The PROFILE must appear in the path — a wrong profile here was the exact
  # "wrong store path" risk that made this function worth executing in a test.
  [ -f "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json" ]
  [ ! -e "$TEST_TMPDIR/state/.openclaw-edge/cron/jobs.json" ]
}

@test "reimport: a different profile writes a different store, never main's" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk ok

  run cron_store_reimport edge "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/state/.openclaw-edge/cron/jobs.json" ]
  [ ! -e "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json" ]
}

@test "reimport: the installed jobs file is 0600 (it carries agent prompts)" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk ok

  cron_store_reimport main "$REPO_JSON"
  perms=$(stat -c '%a' "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json" 2>/dev/null \
          || stat -f '%Lp' "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json")
  [ "$perms" = "600" ]
}

@test "reimport: a missing SDK fails instead of silently doing nothing" {
  setup_converge
  stub_sdk missing

  run cron_store_reimport main "$REPO_JSON"
  [ "$status" -ne 0 ]
}

@test "reimport: a failing 'npm root -g' fails loud" {
  setup_converge
  stub_sdk npmfail

  run cron_store_reimport main "$REPO_JSON"
  [ "$status" -ne 0 ]
}

@test "reimport: an SDK write error propagates as a non-zero rc" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk savefail

  run cron_store_reimport main "$REPO_JSON"
  [ "$status" -ne 0 ]
}

@test "reimport: a short read-back returns the WRONG count, which converge rejects" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk shortread

  run --separate-stderr cron_store_reimport main "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]          # read-back saw 1 row, repo declares 3

  # End to end: converge must turn that into rc 6, not a silent pass.
  CRON_STORE_JOBSET_FN=_jobset_clobbered
  CRON_STORE_REIMPORT_FN=cron_store_reimport
  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 6 ]
}

@test "reimport: a missing repo file fails before touching the store" {
  setup_converge
  stub_sdk ok

  run cron_store_reimport main "$TEST_TMPDIR/nope.json"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json" ]
}

# --- schedule-shape coverage (every kind, and the injected field) -----------

@test "every-kind: a changed everyMs is detected (expr/tz alone would miss it)" {
  _jobs_every > "$TEST_TMPDIR/every.json"
  want=$(cron_store_repo_jobset "$TEST_TMPDIR/every.json")
  got=$(cron_store_jobset_from_json "$(_jobs_every_interval_changed)")
  [ "$want" != "$got" ]
  diff=$(cron_store_diff "$want" "$got")
  [[ "$diff" == *'"changed":["e1"]'* ]]
}

@test "every-kind: a changed anchorMs is detected" {
  _jobs_every > "$TEST_TMPDIR/every.json"
  want=$(cron_store_repo_jobset "$TEST_TMPDIR/every.json")
  got=$(cron_store_jobset_from_json "$(_jobs_every_anchor_changed)")
  [ "$want" != "$got" ]
  diff=$(cron_store_diff "$want" "$got")
  [[ "$diff" == *'"changed":["e2"]'* ]]
}

@test "every-kind: identical every-jobs compare equal" {
  _jobs_every > "$TEST_TMPDIR/every.json"
  want=$(cron_store_repo_jobset "$TEST_TMPDIR/every.json")
  got=$(cron_store_jobset_from_json "$(_jobs_every)")
  [ "$want" = "$got" ]
}

@test "converge: an everyMs drift on an every-job is caught, not passed" {
  setup_converge
  _jobs_every > "$TEST_TMPDIR/cron-jobs.json"
  _jobset_every_changed() { cron_store_jobset_from_json "$(_jobs_every_interval_changed)"; }
  CRON_STORE_JOBSET_FN=_jobset_every_changed
  _reimport_two() { printf '2'; }
  CRON_STORE_REIMPORT_FN=_reimport_two

  run cron_store_converge main "$TEST_TMPDIR/cron-jobs.json"
  [ "$status" -eq 9 ]
}

@test "gateway-injected staggerMs does not trigger a heal" {
  # Measured on node-8 2026-08-11: the gateway defaults staggerMs=300000 on some
  # cron jobs and the repo never declares it. Step 6b cannot heal a default, so
  # treating it as drift would re-import, restart, mismatch again and fail the
  # deploy — every deploy. This asserts the END-TO-END consequence: converge
  # returns 0 and touches nothing.
  setup_converge
  _jobset_stagger() { cron_store_jobset_from_json "$(_jobs_full_with_stagger)"; }
  CRON_STORE_JOBSET_FN=_jobset_stagger
  CRON_STORE_REIMPORT_FN=_reimport_boom

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ "$(_restart_count)" = "0" ]
}

@test "gateway-injected keys are ignored, repo-declared ones are not" {
  # The gateway adds keys cron-jobs.json never declares (measured on node-8:
  # schedule.staggerMs, plus top-level status/lastRunAtMs/nextRunAtMs/...).
  # Those are DEFAULTS, not clobbers: comparing them would red every deploy and
  # Step 6b cannot heal a default. `restrict` drops them automatically, with no
  # list to maintain — this test is what stops someone "simplifying" that away.
  setup_converge
  want=$(cron_store_repo_jobset "$REPO_JSON")
  injected='{"jobs":[
    {"id":"j1","agentId":"ops","name":"one","enabled":true,"status":"idle","lastRunAtMs":123,"nextRunAtMs":456,"deleteAfterRun":false,"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC","staggerMs":300000}},
    {"id":"j2","agentId":"ops","name":"two","enabled":false,"lastRunStatus":"ok","schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC","staggerMs":300000}},
    {"id":"j3","agentId":"ops","name":"three","enabled":true,"schedule":{"kind":"cron","expr":"15 */4 * * *","tz":"UTC","staggerMs":300000}}
  ]}'
  got=$(cron_store_jobset_from_json "$injected")
  d=$(cron_store_diff "$want" "$got")
  run cron_store_diff_is_empty "$d"
  [ "$status" -eq 0 ]
}

@test "runtime bookkeeping (state, updatedAtMs) is excluded on both sides" {
  # The REPO declares both keys — cron-jobs.json commits updatedAtMs for every
  # job and state:{"consecutiveErrors":0} for two of them. So `restrict` alone
  # does NOT save us here: because the template declares them, they would be
  # compared unless canon deletes them. And they drift constantly: updatedAtMs
  # already differed on 4 of 33 live jobs, and state changes the moment a cron
  # runs or errors. Comparing either reds deploys for reasons unrelated to what
  # a cron does.
  repo='{"jobs":[
    {"id":"r1","agentId":"ops","name":"one","enabled":true,"updatedAtMs":1000,"state":{"consecutiveErrors":0},"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}},
    {"id":"r2","agentId":"ops","name":"two","enabled":true,"updatedAtMs":2000,"state":{"consecutiveErrors":0},"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"}}
  ]}'
  live='{"jobs":[
    {"id":"r1","agentId":"ops","name":"one","enabled":true,"updatedAtMs":9999999,"state":{"consecutiveErrors":7,"lastRunAtMs":123},"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}},
    {"id":"r2","agentId":"ops","name":"two","enabled":true,"updatedAtMs":8888888,"state":{"consecutiveErrors":3},"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"}}
  ]}'
  want=$(cron_store_jobset_from_json "$repo")
  got=$(cron_store_jobset_from_json "$live")
  d=$(cron_store_diff "$want" "$got")
  run cron_store_diff_is_empty "$d"
  [ "$status" -eq 0 ]
  # The exclusion list names exactly these two, and nothing else.
  [ "$CRON_STORE_RUNTIME_KEYS" = "state updatedAtMs" ]
}

@test "excluding runtime keys does not blind the fields next to them" {
  # Guard against over-deleting: same repo-declared state/updatedAtMs, but the
  # schedule really did change. Must still be caught.
  repo='{"jobs":[
    {"id":"r1","agentId":"ops","name":"one","enabled":true,"updatedAtMs":1000,"state":{"consecutiveErrors":0},"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}}
  ]}'
  live='{"jobs":[
    {"id":"r1","agentId":"ops","name":"one","enabled":true,"updatedAtMs":9999999,"state":{"consecutiveErrors":7},"schedule":{"kind":"cron","expr":"0 6 * * *","tz":"UTC"}}
  ]}'
  want=$(cron_store_jobset_from_json "$repo")
  got=$(cron_store_jobset_from_json "$live")
  d=$(cron_store_diff "$want" "$got")
  run cron_store_diff_is_empty "$d"
  [ "$status" -ne 0 ]
  [[ "$d" == *'"changed":["r1"]'* ]]
}

# --- execution + delivery drift (same count, same ids, same schedule) -------
#
# The clobber shape a schedule-only comparison misses: the gateway keeps the
# right jobs on the right cadence but runs the OLD work, or delivers it to the
# OLD target.

_jobs_exec() {
  printf '%s' '{"jobs":[
    {"id":"x1","agentId":"ops","name":"cmd","enabled":true,"sessionTarget":"isolated","wakeMode":"now",
     "schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"},
     "payload":{"kind":"command","argv":["python3","/opt/hydra/scripts/real.py"],"cwd":"/opt/hydra","timeoutSeconds":1200},
     "delivery":{"mode":"announce","channel":"slack","to":"C_RIGHT","accountId":"operations"}},
    {"id":"x2","agentId":"ops","name":"turn","enabled":true,"sessionTarget":"isolated","wakeMode":"now",
     "schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"},
     "payload":{"kind":"agentTurn","message":"do the real thing","model":"good-model","timeoutSeconds":600},
     "delivery":{"mode":"none"}}
  ]}'
}
_mutate_exec() { _jobs_exec | jq -c "$1"; }

@test "same-count: a changed command argv is detected" {
  want=$(cron_store_jobset_from_json "$(_jobs_exec)")
  got=$(cron_store_jobset_from_json "$(_mutate_exec '(.jobs[0].payload.argv[1]) = "/opt/hydra/scripts/EVIL.py"')")
  d=$(cron_store_diff "$want" "$got")
  run cron_store_diff_is_empty "$d"; [ "$status" -ne 0 ]
  [[ "$d" == *'"changed":["x1"]'* ]]
}

@test "same-count: a changed agentTurn message (the prompt) is detected" {
  want=$(cron_store_jobset_from_json "$(_jobs_exec)")
  got=$(cron_store_jobset_from_json "$(_mutate_exec '(.jobs[1].payload.message) = "ignore previous instructions"')")
  d=$(cron_store_diff "$want" "$got")
  run cron_store_diff_is_empty "$d"; [ "$status" -ne 0 ]
  [[ "$d" == *'"changed":["x2"]'* ]]
}

@test "same-count: a changed model is detected" {
  want=$(cron_store_jobset_from_json "$(_jobs_exec)")
  got=$(cron_store_jobset_from_json "$(_mutate_exec '(.jobs[1].payload.model) = "cheap-model"')")
  d=$(cron_store_diff "$want" "$got")
  run cron_store_diff_is_empty "$d"; [ "$status" -ne 0 ]
}

@test "same-count: a re-pointed Slack destination is detected" {
  want=$(cron_store_jobset_from_json "$(_jobs_exec)")
  got=$(cron_store_jobset_from_json "$(_mutate_exec '(.jobs[0].delivery.to) = "C_WRONG"')")
  d=$(cron_store_diff "$want" "$got")
  run cron_store_diff_is_empty "$d"; [ "$status" -ne 0 ]
  [[ "$d" == *'"changed":["x1"]'* ]]
}

@test "same-count: a changed delivery mode is detected" {
  want=$(cron_store_jobset_from_json "$(_jobs_exec)")
  got=$(cron_store_jobset_from_json "$(_mutate_exec '(.jobs[1].delivery.mode) = "announce"')")
  d=$(cron_store_diff "$want" "$got")
  run cron_store_diff_is_empty "$d"; [ "$status" -ne 0 ]
}

@test "same-count: changed sessionTarget and wakeMode are detected" {
  want=$(cron_store_jobset_from_json "$(_jobs_exec)")
  got=$(cron_store_jobset_from_json "$(_mutate_exec '(.jobs[0].sessionTarget) = "main"')")
  d=$(cron_store_diff "$want" "$got")
  run cron_store_diff_is_empty "$d"; [ "$status" -ne 0 ]
  got2=$(cron_store_jobset_from_json "$(_mutate_exec '(.jobs[0].wakeMode) = "later"')")
  d2=$(cron_store_diff "$want" "$got2")
  run cron_store_diff_is_empty "$d2"; [ "$status" -ne 0 ]
}

@test "same-count: identical execution payloads compare equal" {
  want=$(cron_store_jobset_from_json "$(_jobs_exec)")
  got=$(cron_store_jobset_from_json "$(_jobs_exec)")
  d=$(cron_store_diff "$want" "$got")
  run cron_store_diff_is_empty "$d"; [ "$status" -eq 0 ]
}

@test "converge: an execution-payload clobber is caught, not passed" {
  setup_converge
  _jobs_exec > "$TEST_TMPDIR/cron-jobs.json"
  _jobset_exec_tampered() {
    cron_store_jobset_from_json "$(_mutate_exec '(.jobs[0].payload.argv[1]) = "/opt/hydra/scripts/EVIL.py"')"
  }
  CRON_STORE_JOBSET_FN=_jobset_exec_tampered
  _reimport_two() { printf '2'; }
  CRON_STORE_REIMPORT_FN=_reimport_two

  run cron_store_converge main "$TEST_TMPDIR/cron-jobs.json"
  [ "$status" -eq 9 ]
}

# --- never destroy a live-created durable cron -------------------------------

_jobs_full_plus_live_extra() {
  printf '%s' '{"jobs":[
    {"id":"j1","agentId":"ops","name":"one","enabled":true,"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}},
    {"id":"j2","agentId":"ops","name":"two","enabled":false,"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"}},
    {"id":"j3","agentId":"ops","name":"three","enabled":true,"schedule":{"kind":"cron","expr":"15 */4 * * *","tz":"UTC"}},
    {"id":"live-mrr","agentId":"finance","name":"Realtime MRR Movement","enabled":true,"schedule":{"kind":"every","everyMs":300000,"anchorMs":1}}
  ]}'
}

@test "converge: REFUSES to heal when the gateway holds an undeclared durable cron" {
  # The re-import is delete-by-store-key, so healing here would DELETE a
  # recurring job someone created live — after deploy.sh's store-only guard
  # already ran, silently bypassing the halt it exists to produce. This is the
  # 2026-07-16 ChartMogul loss shape.
  setup_converge
  _jobset_extra() { cron_store_jobset_from_json "$(_jobs_full_plus_live_extra)"; }
  CRON_STORE_JOBSET_FN=_jobset_extra
  CRON_STORE_REIMPORT_FN=_reimport_boom   # must never run

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 10 ]
  [ "$(_restart_count)" = "0" ]
}

@test "converge: refuses even when a REAL clobber is present alongside the extra job" {
  # Missing j3 (a genuine clobber) AND an undeclared live job. Fixing the
  # clobber must not be an excuse to delete the live job.
  setup_converge
  _jobset_both() {
    cron_store_jobset_from_json '{"jobs":[
      {"id":"j1","agentId":"ops","name":"one","enabled":true,"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}},
      {"id":"j2","agentId":"ops","name":"two","enabled":false,"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"}},
      {"id":"live-mrr","agentId":"finance","name":"Realtime MRR Movement","enabled":true,"schedule":{"kind":"every","everyMs":300000,"anchorMs":1}}
    ]}'
  }
  CRON_STORE_JOBSET_FN=_jobset_both
  CRON_STORE_REIMPORT_FN=_reimport_boom

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 10 ]
  [ "$(_restart_count)" = "0" ]
}

@test "converge: an ephemeral one-shot appearing during the drain is NOT an undeclared cron" {
  # qa-autoreview mints these constantly. They are excluded from the job set, so
  # they must never trip the refusal or the heal.
  setup_converge
  _jobset_eph() {
    cron_store_jobset_from_json '{"jobs":[
      {"id":"j1","agentId":"ops","name":"one","enabled":true,"schedule":{"kind":"cron","expr":"0 1 * * *","tz":"UTC"}},
      {"id":"j2","agentId":"ops","name":"two","enabled":false,"schedule":{"kind":"cron","expr":"0 2 * * *","tz":"UTC"}},
      {"id":"j3","agentId":"ops","name":"three","enabled":true,"schedule":{"kind":"cron","expr":"15 */4 * * *","tz":"UTC"}},
      {"id":"qa-9","name":"qa-autoreview-pr-9","schedule":{"kind":"at"},"deleteAfterRun":true}
    ]}'
  }
  CRON_STORE_JOBSET_FN=_jobset_eph
  CRON_STORE_REIMPORT_FN=_reimport_boom

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ "$(_restart_count)" = "0" ]
}

# --- the heal must not erase live scheduler state ---------------------------

@test "reimport: preserves live per-job state instead of resetting it" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk ok
  # Seed a store that already carries runtime state for two of the repo's jobs.
  mkdir -p "$TEST_TMPDIR/state/.openclaw-main/cron"
  printf '%s' '{"jobs":[
    {"id":"j1","state":{"lastRunAtMs":111,"consecutiveErrors":4}},
    {"id":"j2","state":{"lastRunAtMs":222,"consecutiveErrors":0}}
  ]}' > "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json.sqlite-sim"

  # --separate-stderr: the function warns on stderr (e.g. an unreadable live
  # store) and bats' plain `run` would fold that into $output.
  run --separate-stderr cron_store_reimport main "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  saved="$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json.sqlite-sim"
  [ "$(jq -r '.jobs[]|select(.id=="j1")|.state.lastRunAtMs' "$saved")" = "111" ]
  [ "$(jq -r '.jobs[]|select(.id=="j1")|.state.consecutiveErrors' "$saved")" = "4" ]
  [ "$(jq -r '.jobs[]|select(.id=="j2")|.state.lastRunAtMs' "$saved")" = "222" ]
  # A job with no prior state stays stateless rather than gaining a bogus one.
  [ "$(jq -r '.jobs[]|select(.id=="j3")|.state' "$saved")" = "null" ]
}

@test "reimport: an ABSENT live store is fine — there is nothing to destroy" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk ok
  # No pre-existing store file: loadCronStore returns an empty set rather than
  # throwing, so the heal proceeds. Distinct from an UNREADABLE store below.
  run --separate-stderr cron_store_reimport main "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "reimport: FAILS CLOSED when the live store cannot be read, and never saves" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk loadfail
  # Seed a store so we can prove it was left untouched.
  mkdir -p "$TEST_TMPDIR/state/.openclaw-main/cron"
  printf '%s' '{"jobs":[{"id":"pre-existing","state":{"lastRunAtMs":42}}]}' \
    > "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json.sqlite-sim"
  before=$(cat "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json.sqlite-sim")

  run --separate-stderr cron_store_reimport main "$REPO_JSON"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"refusing to save"* ]]
  # The save never ran: the store is byte-identical.
  [ "$(cat "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json.sqlite-sim")" = "$before" ]
}

@test "converge: maps an unreadable live store to rc 12, not a generic failure" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk loadfail
  CRON_STORE_JOBSET_FN=_jobset_clobbered
  CRON_STORE_REIMPORT_FN=cron_store_reimport

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 12 ]
}

# --- the snapshot -> save window --------------------------------------------

@test "reimport: ABORTS when a durable cron appears between the snapshot and the save" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk concurrent-add

  run --separate-stderr cron_store_reimport main "$REPO_JSON"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"added-during-drain"* ]]
  # Nothing was written: the save never ran.
  [ ! -e "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json.sqlite-sim" ]
}

@test "converge: maps that abort to rc 11 rather than a generic import failure" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk concurrent-add
  CRON_STORE_JOBSET_FN=_jobset_clobbered      # a real clobber, so the heal is attempted
  CRON_STORE_REIMPORT_FN=cron_store_reimport  # the REAL one

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 11 ]
}

@test "reimport: an ephemeral one-shot appearing in that window does NOT abort" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk ok
  mkdir -p "$TEST_TMPDIR/state/.openclaw-main/cron"
  printf '%s' '{"jobs":[{"id":"qa-77","name":"qa-autoreview-pr-77","schedule":{"kind":"at"},"deleteAfterRun":true}]}' \
    > "$TEST_TMPDIR/state/.openclaw-main/cron/jobs.json.sqlite-sim"

  run --separate-stderr cron_store_reimport main "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "reimport: HYDRA_ALLOW_ORPHAN_CRON=1 overrides the abort, as deploy.sh's guard allows" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  setup_converge
  stub_sdk concurrent-add
  export HYDRA_ALLOW_ORPHAN_CRON=1
  run --separate-stderr cron_store_reimport main "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "converge: HYDRA_ALLOW_ORPHAN_CRON=1 turns the rc-10 refusal into a logged drop" {
  setup_converge
  _jobset_extra() { cron_store_jobset_from_json "$(_jobs_full_plus_live_extra)"; }
  CRON_STORE_JOBSET_FN=_jobset_extra
  _jobset_heals() { if [ -s "$RESTART_LOG" ]; then _jobset_full; else _jobset_extra; fi; }
  CRON_STORE_JOBSET_FN=_jobset_heals

  export HYDRA_ALLOW_ORPHAN_CRON=1
  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 1 ]          # healed, deliberately dropping the extra job
}

@test "converge: WITHOUT the override the same case still refuses" {
  setup_converge
  _jobset_extra() { cron_store_jobset_from_json "$(_jobs_full_plus_live_extra)"; }
  CRON_STORE_JOBSET_FN=_jobset_extra
  CRON_STORE_REIMPORT_FN=_reimport_boom

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 10 ]
}

# --- the import must be an EXCLUSIVE critical section ------------------------

@test "converge: the import happens BETWEEN a stop and a start, never alongside a live gateway" {
  # This is the whole point of the stop: saveCronStore is replace-all with no
  # compare-and-swap, and the gateway is the only writer of the cron store
  # (verified on node-8: one process holds openclaw.sqlite open). Ordering IS
  # the safety property, so it is asserted directly rather than inferred.
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_heals

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 1 ]
  [ "$(_lifecycle)" = "stop main import start main " ]
}

@test "converge: a failed STOP means the import never runs and nothing is touched" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_clobbered
  CRON_STORE_STOP_FN=_stop_fail
  CRON_STORE_REIMPORT_FN=_reimport_boom   # must never run

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 13 ]
  [[ "$(_lifecycle)" != *"import"* ]]
  [[ "$(_lifecycle)" != *"start"* ]]   # nothing was stopped, so nothing to start
}

@test "converge: a failed START is rc 14 — the loudest thing it can say" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_clobbered
  CRON_STORE_START_FN=_start_fail

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 14 ]
}

@test "converge: rc 14 wins over a re-import failure — a down fleet outranks a bad import" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_clobbered
  CRON_STORE_REIMPORT_FN=_reimport_fail
  CRON_STORE_START_FN=_start_fail

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 14 ]
}

@test "converge: paths that never stop the gateway also never start it" {
  # no-drift, unknown, paginated and the rc-10 refusal must not touch the
  # gateway at all.
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_full
  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 0 ]
  [ "$(_lifecycle)" = "" ]
}

@test "converge: an UNCOMPUTABLE diff returns 15 and never stops or imports" {
  # converge always runs in an `||` context, so set -e is off for its whole
  # body. A failed diff used to leave CRON_STORE_DIFF empty, which made the
  # .unexpected probe find nothing and walked straight into the stop +
  # replace-all heal without knowing what differed.
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_clobbered
  CRON_STORE_REIMPORT_FN=_reimport_boom
  cron_store_diff() { return 1; }          # shadow the real one

  run cron_store_converge main "$REPO_JSON"
  [ "$status" -eq 15 ]
  [ "$(_lifecycle)" = "" ]                 # nothing stopped, imported or started
}

@test "converge: an uncomputable diff AFTER the heal is 16, not 15 — the timeline differs" {
  setup_converge
  CRON_STORE_JOBSET_FN=_jobset_heals
  # Succeed on the pre-heal diff, fail on the post-heal one.
  _diff_calls="$TEST_TMPDIR/diffcalls"; : > "$_diff_calls"
  cron_store_diff() {
    printf 'x\n' >> "$_diff_calls"
    if [ "$(wc -l < "$_diff_calls" | tr -d ' ')" -ge 2 ]; then return 1; fi
    printf '%s' '{"missing":["j3"],"unexpected":[],"changed":[]}'
  }

  run cron_store_converge main "$REPO_JSON"
  # 16, not 15: the gateway was stopped, the store rewritten and the gateway
  # restarted before this diff ran. Reusing 15 would tell the operator none of
  # that happened.
  [ "$status" -eq 16 ]
  [ "$(_lifecycle)" = "stop main import start main " ]
}

# --- the diff must never fail OPEN ------------------------------------------

@test "a malformed diff is NOT read as 'nothing differs'" {
  # cron_store_diff returning junk once made converge report success. Requiring
  # all three array keys is what makes that impossible.
  for bad in '{"diff":"unavailable"}' '' 'garbage' '{}' '{"missing":[],"unexpected":[]}' 'null' '[]'; do
    run cron_store_diff_is_empty "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "a well-formed empty diff IS read as 'nothing differs'" {
  run cron_store_diff_is_empty '{"missing":[],"unexpected":[],"changed":[]}'
  [ "$status" -eq 0 ]
}

# --- the incident this file exists for -------------------------------------

@test "2026-08-11 regression: repo 33 vs gateway 32 is a MISMATCH, not a rounding artifact" {
  # 33 repo jobs, 17 of them disabled; the gateway lost exactly the one the
  # deploy was adding and also carries 9 live ephemeral one-shots.
  repo='{"jobs":['
  for i in $(seq 1 33); do
    [ "$i" -gt 1 ] && repo+=','
    repo+="{\"id\":\"$i\"}"
  done
  repo+=']}'
  printf '%s' "$repo" > "$TEST_TMPDIR/cron-jobs.json"

  loaded='{"jobs":['
  for i in $(seq 1 32); do
    [ "$i" -gt 1 ] && loaded+=','
    en=true; [ "$i" -le 17 ] && en=false
    loaded+="{\"name\":\"j$i\",\"enabled\":$en,\"schedule\":{\"kind\":\"cron\"}}"
  done
  for i in $(seq 1 9); do
    loaded+=",{\"name\":\"qa-$i\",\"schedule\":{\"kind\":\"at\"},\"deleteAfterRun\":true}"
  done
  loaded+=']}'

  run cron_store_repo_count "$TEST_TMPDIR/cron-jobs.json"
  [ "$status" -eq 0 ]
  expected="$output"

  run cron_store_durable_count_from_json "$loaded"
  [ "$status" -eq 0 ]
  actual="$output"

  [ "$expected" = "33" ]
  [ "$actual" = "32" ]
  [ "$expected" != "$actual" ]
}
