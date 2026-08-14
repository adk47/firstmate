#!/usr/bin/env bats
# Tests for scripts/qa-dispatch-pr-review.sh — the fire-and-forget dispatcher
# that registers a one-shot openclaw cron job to auto-review a hydra PR.
# Every test PATH-shadows `openclaw` with a stub so the suite NEVER touches the
# live gateway (memory: bats must stub openclaw/gh — an unstubbed test once
# fired 9 real Slack alerts to prod). Arg-validation tests must reject BEFORE
# any openclaw call, so a bad invocation can never dispatch a real review.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-dispatch-pr-review.sh"

GOOD_SHA="0f175183abf"   # 11 hex chars — valid
NICK="U0AL36NADEY"       # a requester UID; REQUIRED now — the script has no default

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export STUB_CALLS="$TEST_TMPDIR/calls"          # one token per subcommand
  export STUB_ARGV="$TEST_TMPDIR/argv"            # every arg, one per line
  : > "$STUB_CALLS"
  : > "$STUB_ARGV"

  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/openclaw" <<'STUB'
#!/usr/bin/env bash
# Record every arg for assertions.
printf '%s\n' "$@" >> "$STUB_ARGV"
# Find the cron subcommand (the word after "cron").
sub=""
prev=""
for a in "$@"; do
  if [ "$prev" = "cron" ]; then sub="$a"; break; fi
  prev="$a"
done
case "$sub" in
  # `cron list` returns STUB_LIST_JSON if a test set one, else no jobs. A test
  # can also force the call to fail outright (STUB_LIST_FAIL) or return raw
  # garbage (STUB_LIST_GARBAGE) to prove the sweep degrades safely.
  list)
    if [ -n "${STUB_LIST_FAIL:-}" ]; then exit 1; fi
    if [ -n "${STUB_LIST_GARBAGE:-}" ]; then echo "not json at all"; exit 0; fi
    if [ -f "${STUB_LIST_JSON:-}" ]; then cat "${STUB_LIST_JSON}"; else echo '{"jobs":[]}'; fi
    ;;
  add)  echo "cron-add" >> "$STUB_CALLS"; echo '{"ok":true}' ;;
  rm)   echo "cron-rm"  >> "$STUB_CALLS" ;;
esac
STUB
  chmod +x "$STUBBIN/openclaw"
  export PATH="$STUBBIN:$PATH"
  export OPENCLAW="openclaw"   # resolve via the stubbed PATH
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "happy path: dispatches one cron add for the qa agent on main" {
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
  # targets the qa agent, the main profile, and the per-PR job name (now
  # namespaced by repo: the 2-arg default resolves to Muso-AI/hydra).
  grep -qx 'qa' "$STUB_ARGV"
  grep -qx 'main' "$STUB_ARGV"
  grep -qx 'qa-autoreview-pr-Muso-AI-hydra-123' "$STUB_ARGV"
  grep -qx 'isolated' "$STUB_ARGV"
  grep -qx -- '--delete-after-run' "$STUB_ARGV"
}

@test "happy path: message carries the PR URL + AUTO-REVIEW + the passed requester UID" {
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  grep -q 'AUTO-REVIEW' "$STUB_ARGV"
  grep -q 'github.com/Muso-AI/hydra/pull/123' "$STUB_ARGV"
  grep -q 'U0AL36NADEY' "$STUB_ARGV"
}

@test "happy path: opening DM routed through the per-PR thread helper" {
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  # The opening note goes through qa-pr-thread-dm.sh (threads re-reviews), not a
  # bare qa-slack-dm.sh call with an inline "reviewing PR" string.
  grep -q 'qa-pr-thread-dm.sh Muso-AI/hydra 123 U0AL36NADEY' "$STUB_ARGV"
}

@test "requester UID absent from BOTH the 4th arg and the env -> exit 2, no dispatch" {
  # B1: the dispatcher used to default this to Nick's UNSCOPED UID, so a two-arg
  # manual dispatch of ANY author's PR silently carried his approval authority and
  # logged him as the requester. There must be no default at all.
  run env -u QA_REVIEW_REQUESTER_UID "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'requester-uid is REQUIRED'
  [ ! -s "$STUB_CALLS" ]
}

@test "the removed default UID appears nowhere in the dispatcher as a fallback" {
  # Pins the fix itself: a literal personal UID on the REQUESTER_UID assignment is
  # the exact shape that regressed. (The UID may legitimately appear in comments.)
  if grep -qE '^REQUESTER_UID=.*U[A-Z0-9]{6,}' "$SCRIPT"; then
    echo "REQUESTER_UID still carries a hardcoded personal Slack UID fallback" >&2; false
  fi
}

@test "missing args -> usage exit 2, no dispatch" {
  run "$SCRIPT" 123
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "too many args (>4) -> usage exit 2, no dispatch" {
  run "$SCRIPT" 123 "$GOOD_SHA" "Muso-AI/ads-manager" "U03TYGJF1N3" extra
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "non-numeric PR -> exit 2 BEFORE any openclaw call" {
  run "$SCRIPT" not-a-number "$GOOD_SHA"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "bad SHA (non-hex) -> exit 2 BEFORE any openclaw call" {
  run "$SCRIPT" 123 "zzz-not-hex"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "bad SHA (too short) -> exit 2" {
  run "$SCRIPT" 123 "abc"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "4-arg form: dispatches an ads-manager review with the passed repo + UID" {
  run "$SCRIPT" 123 "$GOOD_SHA" "Muso-AI/ads-manager" "U03TYGJF1N3"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
  # job name namespaced by repo (no collision with hydra#123)
  grep -qx 'qa-autoreview-pr-Muso-AI-ads-manager-123' "$STUB_ARGV"
  # the message points the skill at ads-manager, not hydra
  grep -q 'github.com/Muso-AI/ads-manager/pull/123' "$STUB_ARGV"
  grep -q 'U03TYGJF1N3' "$STUB_ARGV"
  grep -q 'qa-pr-thread-dm.sh Muso-AI/ads-manager 123 U03TYGJF1N3' "$STUB_ARGV"
  grep -q 'gh pr checks 123 --repo Muso-AI/ads-manager' "$STUB_ARGV"
}

@test "env overrides set repo + requester when positionals are absent" {
  QA_REVIEW_REPO="Muso-AI/ads-manager" QA_REVIEW_REQUESTER_UID="U03TYGJF1N3" \
    run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  grep -qx 'qa-autoreview-pr-Muso-AI-ads-manager-123' "$STUB_ARGV"
  grep -q 'github.com/Muso-AI/ads-manager/pull/123' "$STUB_ARGV"
}

@test "positional repo/UID win over env" {
  QA_REVIEW_REPO="Muso-AI/hydra" QA_REVIEW_REQUESTER_UID="U0AL36NADEY" \
    run "$SCRIPT" 123 "$GOOD_SHA" "Muso-AI/ads-manager" "U03TYGJF1N3"
  [ "$status" -eq 0 ]
  grep -qx 'qa-autoreview-pr-Muso-AI-ads-manager-123' "$STUB_ARGV"
  grep -q 'U03TYGJF1N3' "$STUB_ARGV"
}

@test "non-Muso-AI repo -> exit 2 BEFORE any openclaw call" {
  run "$SCRIPT" 123 "$GOOD_SHA" "evil-org/ads-manager"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "malformed requester UID -> exit 2 BEFORE any openclaw call" {
  run "$SCRIPT" 123 "$GOOD_SHA" "Muso-AI/ads-manager" "not-a-uid"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "fallback delivery disabled via --no-deliver (skill owns Slack delivery)" {
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  # --no-deliver is the actual off-switch for the runner's fallback delivery. Without
  # it the isolated cron's final text delivery fails with "Delivering to Slack requires
  # target ..." (omitting --announce alone does NOT disable the fallback).
  grep -qx -- '--no-deliver' "$STUB_ARGV"
  ! grep -qx -- '--announce'  "$STUB_ARGV"
}

# --- stale sweep: run-evidence, not elapsed time ---------------------------
#
# Premise: a job is only safe to reap once it has COMPLETED a run
# (.state.lastRunAtMs present and old enough to rule out "still running"). A
# createdAt-only cutoff used to reap jobs that queued and never fired
# (muso-skills#2, core-backend#9243) -- these tests pin the new predicate.

@test "job with completed run older than 1800s -> IS rm'd (exact id)" {
  now_ms=$(( $(date -u +%s) * 1000 ))
  old_done_ms=$(( now_ms - 2000000 ))  # ~33min ago, > 1800s cutoff
  export STUB_LIST_JSON="$TEST_TMPDIR/list.json"
  cat > "$STUB_LIST_JSON" <<JSON
{"jobs":[
  {"id":"OLDDONE","name":"qa-autoreview-pr-Muso-AI-hydra-999","state":{"lastRunAtMs":$old_done_ms}}
]}
JSON
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  grep -qx 'OLDDONE' "$STUB_ARGV"
  [ "$(grep -c '^cron-rm$' "$STUB_CALLS")" -eq 1 ]
}

@test "job with NO .state.lastRunAtMs, created 3h ago -> NOT rm'd, and it is logged" {
  now_ms=$(( $(date -u +%s) * 1000 ))
  old_created_ms=$(( now_ms - 10800000 ))  # 3h ago
  export STUB_LIST_JSON="$TEST_TMPDIR/list.json"
  cat > "$STUB_LIST_JSON" <<JSON
{"jobs":[
  {"id":"NEVERRUN","name":"qa-autoreview-pr-Muso-AI-hydra-998","createdAtMs":$old_created_ms,"state":{"nextRunAtMs":$now_ms}}
]}
JSON
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  ! grep -qx 'NEVERRUN' "$STUB_ARGV"
  [ ! -s "$STUB_CALLS" ] || [ "$(grep -c '^cron-rm$' "$STUB_CALLS")" -eq 0 ]
  echo "$output" | grep -q 'qa-autoreview-pr-Muso-AI-hydra-998'
}

@test "job with .state.runningAtMs and no lastRunAtMs -> NOT rm'd (in flight)" {
  now_ms=$(( $(date -u +%s) * 1000 ))
  running_ms=$(( now_ms - 500 ))
  export STUB_LIST_JSON="$TEST_TMPDIR/list.json"
  cat > "$STUB_LIST_JSON" <<JSON
{"jobs":[
  {"id":"RUNNINGQA","name":"qa-autoreview-pr-Muso-AI-hydra-997","status":"running","state":{"runningAtMs":$running_ms}}
]}
JSON
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  ! grep -qx 'RUNNINGQA' "$STUB_ARGV"
  [ "$(grep -c '^cron-rm$' "$STUB_CALLS" 2>/dev/null)" -eq 0 ]
}

@test "job with .state.lastRunAtMs 60s ago -> NOT rm'd (inside the timeout margin)" {
  now_ms=$(( $(date -u +%s) * 1000 ))
  recent_ms=$(( now_ms - 60000 ))
  export STUB_LIST_JSON="$TEST_TMPDIR/list.json"
  cat > "$STUB_LIST_JSON" <<JSON
{"jobs":[
  {"id":"RECENTQA","name":"qa-autoreview-pr-Muso-AI-hydra-996","state":{"lastRunAtMs":$recent_ms}}
]}
JSON
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  ! grep -qx 'RECENTQA' "$STUB_ARGV"
}

@test "job with BOTH old lastRunAtMs AND runningAtMs -> NOT rm'd (running wins)" {
  now_ms=$(( $(date -u +%s) * 1000 ))
  old_done_ms=$(( now_ms - 2000000 ))  # ~33min ago, > 1800s cutoff
  running_ms=$(( now_ms - 500 ))
  export STUB_LIST_JSON="$TEST_TMPDIR/list.json"
  cat > "$STUB_LIST_JSON" <<JSON
{"jobs":[
  {"id":"RERUNQA","name":"qa-autoreview-pr-Muso-AI-hydra-994","state":{"lastRunAtMs":$old_done_ms,"runningAtMs":$running_ms}}
]}
JSON
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  ! grep -qx 'RERUNQA' "$STUB_ARGV"
  [ "$(grep -c '^cron-rm$' "$STUB_CALLS" 2>/dev/null)" -eq 0 ]
}

@test "job with old lastRunAtMs AND top-level status running -> NOT rm'd" {
  now_ms=$(( $(date -u +%s) * 1000 ))
  old_done_ms=$(( now_ms - 2000000 ))  # ~33min ago, > 1800s cutoff
  export STUB_LIST_JSON="$TEST_TMPDIR/list.json"
  cat > "$STUB_LIST_JSON" <<JSON
{"jobs":[
  {"id":"STATUSRUNQA","name":"qa-autoreview-pr-Muso-AI-hydra-993","status":"running","state":{"lastRunAtMs":$old_done_ms}}
]}
JSON
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  ! grep -qx 'STATUSRUNQA' "$STUB_ARGV"
  [ "$(grep -c '^cron-rm$' "$STUB_CALLS" 2>/dev/null)" -eq 0 ]
}

@test "non-qa job never touched, even when its (fictional) run evidence is stale" {
  now_ms=$(( $(date -u +%s) * 1000 ))
  old_done_ms=$(( now_ms - 2000000 ))
  export STUB_LIST_JSON="$TEST_TMPDIR/list.json"
  cat > "$STUB_LIST_JSON" <<JSON
{"jobs":[
  {"id":"OTHERCRON","name":"some-other-cron","state":{"lastRunAtMs":$old_done_ms}}
]}
JSON
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  ! grep -qx 'OTHERCRON' "$STUB_ARGV"
}

@test "hasMore true -> the sweep is skipped entirely, NO rm calls at all" {
  now_ms=$(( $(date -u +%s) * 1000 ))
  old_done_ms=$(( now_ms - 2000000 ))
  export STUB_LIST_JSON="$TEST_TMPDIR/list.json"
  cat > "$STUB_LIST_JSON" <<JSON
{"hasMore":true,"jobs":[
  {"id":"WOULDBESTALE","name":"qa-autoreview-pr-Muso-AI-hydra-995","state":{"lastRunAtMs":$old_done_ms}}
]}
JSON
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  ! grep -qx 'WOULDBESTALE' "$STUB_ARGV"
  [ "$(grep -c '^cron-rm$' "$STUB_CALLS" 2>/dev/null)" -eq 0 ]
}

@test "cron list returns garbage -> no rm calls, dispatch still succeeds" {
  export STUB_LIST_GARBAGE=1
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-rm$' "$STUB_CALLS" 2>/dev/null)" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "cron list fails outright -> sweep does not fail the dispatch" {
  export STUB_LIST_FAIL=1
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-rm$' "$STUB_CALLS" 2>/dev/null)" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "cron list is called with --all on BOTH the idempotency and stale-sweep calls" {
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  # Two `cron list` invocations happen per dispatch (idempotency cleanup, then
  # the stale sweep) -- both must carry --all, or a disabled row is invisible
  # to whichever one dropped it (bare `cron list` HIDES disabled rows).
  [ "$(grep -cx -- '--all' "$STUB_ARGV")" -eq 2 ]
}
