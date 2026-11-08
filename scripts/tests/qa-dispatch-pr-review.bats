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
  add)
    echo "cron-add" >> "$STUB_CALLS"
    # STUB_ADD_ERR/STUB_ADD_RC simulate a failing `cron add` (stderr text + exit code).
    # STUB_ADD_FAIL_TIMES=N makes only the first N adds fail that way (a gateway
    # that is unreachable for a while and then answers); later adds succeed.
    n="$(grep -c '^cron-add$' "$STUB_CALLS")"
    if [ -n "${STUB_ADD_ERR:-}" ] && { [ -z "${STUB_ADD_FAIL_TIMES:-}" ] || [ "$n" -le "${STUB_ADD_FAIL_TIMES}" ]; }; then
      echo "$STUB_ADD_ERR" >&2
      if [ -n "${STUB_ADD_RC:-}" ]; then exit "$STUB_ADD_RC"; fi
    fi
    echo '{"ok":true}' ;;
  rm)   echo "cron-rm"  >> "$STUB_CALLS" ;;
esac
STUB
  chmod +x "$STUBBIN/openclaw"
  # `gh run list` stub for the in-flight dedup. Records argv; prints STUB_GH_JSON
  # (default: no runs); STUB_GH_FAIL makes the lookup fail (fail-open test).
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_GH_ARGV"
if [ -n "${STUB_GH_FAIL:-}" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
# `gh api repos/<r>/pulls/<n> --jq .head.sha` is the head-freshness lookup the
# broker path makes before enqueueing. STUB_HEAD_SHA is the PR's current head;
# unset means the lookup answers nothing, which the dispatcher treats as
# "unverified" (enqueue, but no supersede rights).
if [ "$1" = "api" ]; then
  # The dispatcher asks for `.head.sha + " " + .updated_at` in ONE read: the
  # sha is the freshness check, the timestamp is the monotonic ordering token.
  if [ -n "${STUB_HEAD_SHA:-}" ]; then
    printf '%s %s\n' "$STUB_HEAD_SHA" "${STUB_HEAD_ORDER:-2026-11-06T00:00:00Z}"
  fi
  exit 0
fi
if [ -f "${STUB_GH_JSON:-}" ]; then cat "$STUB_GH_JSON"; else echo '[]'; fi
STUB
  chmod +x "$STUBBIN/gh"
  export STUB_GH_ARGV="$TEST_TMPDIR/gh_argv"; : > "$STUB_GH_ARGV"
  export PATH="$STUBBIN:$PATH"
  export OPENCLAW="openclaw"   # resolve via the stubbed PATH
  # Transport retries sleep between attempts; the suite must not. Attempts
  # keep their default (3) so every exit-75 test below exercises the real loop.
  export QA_DISPATCH_RETRY_BACKOFF_S="0"
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

@test "happy path: the dispatch prompt does not make the reviewer gate approval on its own CI read (MUS-7727)" {
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  # A model-side "every CI check passed" gate here outranks the skill. It
  # withheld a clean GO on hydra#1119 and #1107 over the advisory Deploy
  # pre-flight. The wrapper owns the CI decision, so the prompt must route to it.
  run grep -q 'ONLY IF every' "$STUB_ARGV"
  [ "$status" -ne 0 ]
  run grep -q 'Check CI with' "$STUB_ARGV"
  [ "$status" -ne 0 ]
  grep -q 'scripts/qa-pr-approve.sh' "$STUB_ARGV"
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
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
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
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
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
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
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
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
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
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
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
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
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
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  ! grep -qx 'WOULDBESTALE' "$STUB_ARGV"
  [ "$(grep -c '^cron-rm$' "$STUB_CALLS" 2>/dev/null)" -eq 0 ]
}

@test "cron list returns garbage -> no rm calls, dispatch still succeeds" {
  export STUB_LIST_GARBAGE=1
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-rm$' "$STUB_CALLS" 2>/dev/null)" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "cron list fails outright -> sweep does not fail the dispatch" {
  export STUB_LIST_FAIL=1
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-rm$' "$STUB_CALLS" 2>/dev/null)" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "cron list is called with --all on BOTH the idempotency and stale-sweep calls" {
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  # Two `cron list` invocations happen per dispatch (idempotency cleanup, then
  # the stale sweep) -- both must carry --all, or a disabled row is invisible
  # to whichever one dropped it (bare `cron list` HIDES disabled rows).
  [ "$(grep -cx -- '--all' "$STUB_ARGV")" -eq 2 ]
}

@test "gateway unreachable (handshake timeout) -> exit 75, openclaw's stderr still re-emitted" {
  STUB_ADD_ERR="Error: Opening handshake has timed out" STUB_ADD_RC=1 \
    QA_REVIEW_REQUESTER_UID="$NICK" run --separate-stderr "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 75 ]
  [[ "$stderr" == *"Opening handshake has timed out"* ]]
}

# --- bounded in-place retry on a transport failure (2026-11-06, hydra#1820 @ 086158df) ---

@test "retry: a persistent handshake timeout is attempted 3 times, each attempt named, then exit 75 says so" {
  STUB_ADD_ERR="Error: Opening handshake has timed out" STUB_ADD_RC=1 \
    QA_REVIEW_REQUESTER_UID="$NICK" run --separate-stderr "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 75 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 3 ]
  [[ "$stderr" == *"attempt 1/3"* ]]
  [[ "$stderr" == *"attempt 2/3"* ]]
  [[ "$stderr" == *"after 3/3 attempts"* ]]
  [[ "$stderr" == *"exiting 75 (not an attempt)"* ]]
}

@test "retry: a gateway that answers on the 2nd attempt dispatches exactly one cron and exits 0, naming the retry" {
  STUB_ADD_ERR="Error: Opening handshake has timed out" STUB_ADD_RC=1 STUB_ADD_FAIL_TIMES=1 \
    QA_REVIEW_REQUESTER_UID="$NICK" run --separate-stderr "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  # 2 calls: one refused by transport, one that minted the job. The failed call
  # never queued anything, so exactly ONE review is dispatched, never two.
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 2 ]
  [[ "$output" == *"dispatched auto-review of Muso-AI/hydra#123"* ]]
  [[ "$output" == *"on attempt 2/3"* ]]
  [[ "$stderr" == *"attempt 1/3"* ]]
}

@test "retry: a gateway REJECTION (non-transport failure) is never retried -- one attempt, openclaw's own rc" {
  STUB_ADD_ERR="Error: invalid --at value" STUB_ADD_RC=1 \
    QA_REVIEW_REQUESTER_UID="$NICK" run --separate-stderr "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
  [[ "$stderr" != *"retrying"* ]]
}

@test "retry: QA_DISPATCH_TRANSPORT_ATTEMPTS=1 restores the single-shot behaviour" {
  QA_DISPATCH_TRANSPORT_ATTEMPTS=1 STUB_ADD_ERR="ECONNREFUSED" STUB_ADD_RC=1 \
    QA_REVIEW_REQUESTER_UID="$NICK" run --separate-stderr "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 75 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
  [[ "$stderr" == *"after 1/1 attempts"* ]]
}

@test "retry: the backoff schedule is honoured (last value repeats) and a malformed override falls back" {
  # 3 attempts, schedule "1" -> two sleeps of 1s: measurable, bounded.
  start=$(date +%s)
  QA_DISPATCH_RETRY_BACKOFF_S="1" STUB_ADD_ERR="ECONNREFUSED" STUB_ADD_RC=1 \
    QA_REVIEW_REQUESTER_UID="$NICK" run --separate-stderr "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 75 ]
  [ $(( $(date +%s) - start )) -ge 2 ]
  [[ "$stderr" == *"retrying in 1s"* ]]
}

@test "retry: malformed overrides fall back to the defaults instead of aborting before the dispatch" {
  # Attempts "lots" -> default 3 (backoff 0 from setup keeps it instant).
  QA_DISPATCH_TRANSPORT_ATTEMPTS="lots" STUB_ADD_ERR="ECONNREFUSED" STUB_ADD_RC=1 \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 75 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 3 ]
  # Backoff "soon" with a single attempt: no sleep is ever reached, and the
  # malformed value must not trip set -u/-e on the way to the dispatch.
  : > "$STUB_CALLS"
  QA_DISPATCH_TRANSPORT_ATTEMPTS=1 QA_DISPATCH_RETRY_BACKOFF_S="soon" \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "retry: an AMBIGUOUS transport failure is never retried -- one attempt, exit 75, no second one-shot" {
  # ECONNRESET / socket hang up / fetch failed can be produced AFTER the request
  # was written, so a one-shot may already exist. Retrying would mint a second
  # job for the same PR (two concurrent reviews, two DMs, a second status).
  for sig in "read ECONNRESET" "socket hang up" "TypeError: fetch failed"; do
    : > "$STUB_CALLS"
    STUB_ADD_ERR="$sig" STUB_ADD_RC=1 \
      QA_REVIEW_REQUESTER_UID="$NICK" run --separate-stderr "$SCRIPT" 123 "$GOOD_SHA"
    [ "$status" -eq 75 ]
    [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
    [[ "$stderr" == *"ambiguous"* ]]
    [[ "$stderr" != *"retrying"* ]]
  done
}

@test "each pre-gateway transport signature maps to exit 75, case-insensitively" {
  for sig in "connect ETIMEDOUT 1.2.3.4:18789" "ECONNREFUSED" "read ECONNRESET" "socket hang up" "TypeError: fetch failed" "opening handshake HAS TIMED OUT"; do
    STUB_ADD_ERR="$sig" STUB_ADD_RC=1 QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
    [ "$status" -eq 75 ]
  done
}

@test "an unrelated cron add failure keeps openclaw's exit 1 (75 is not a blanket any-failure)" {
  STUB_ADD_ERR="Error: invalid --at value" STUB_ADD_RC=1 \
    QA_REVIEW_REQUESTER_UID="$NICK" run --separate-stderr "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"invalid --at value"* ]]
}

# --- in-flight dedup (MUS-7955): refuse a duplicate / superseded dispatch -------
# Fixture: one queued dispatch run, named as external-pr-review.yml's run-name.
gh_runs() {  # gh_runs <databaseId> <pr> <sha> [status] [repo] [age-seconds]
  local t; t=$(( $(date -u +%s) - ${6:-0} ))
  t="$(date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ)"
  printf '[{"databaseId":%s,"name":"qa %s#%s @ %s (external-qa-review)","status":"%s","createdAt":"%s"}]\n' \
    "$1" "${5:-Muso-AI/hydra}" "$2" "$3" "${4:-queued}" "$t" > "$TEST_TMPDIR/gh.json"
  export STUB_GH_JSON="$TEST_TMPDIR/gh.json"
}

@test "dedup: lookup asks gh run list for hydra runs with the exact fields (argv, not branches)" {
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$STUB_GH_ARGV")" = "run" ]
  [ "$(sed -n 2p "$STUB_GH_ARGV")" = "list" ]
  grep -qx -- '-R' "$STUB_GH_ARGV"
  grep -qx 'Muso-AI/hydra' "$STUB_GH_ARGV"
  grep -qx -- '--json' "$STUB_GH_ARGV"
  grep -qx 'databaseId,name,status,createdAt' "$STUB_GH_ARGV"
}

@test "dedup: exact (repo,pr,sha) already queued -> refused, exit 0, greppable line, no cron add" {
  gh_runs 100 123 "${GOOD_SHA}0000000000000000000000000000"
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEDUP-REFUSED duplicate"* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "dedup: in_progress duplicate is refused too" {
  gh_runs 100 123 "${GOOD_SHA}0000000000000000000000000000" in_progress
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [[ "$output" == *"DEDUP-REFUSED duplicate"* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "dedup: a COMPLETED run for the same sha does not block a re-send (drop-resender protocol)" {
  gh_runs 100 123 "${GOOD_SHA}0000000000000000000000000000" completed
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "dedup: our OWN run (GITHUB_RUN_ID) is never a duplicate of itself" {
  gh_runs 100 123 "${GOOD_SHA}0000000000000000000000000000" in_progress
  GITHUB_RUN_ID=100 QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "dedup: two queued twins -> only the YOUNGER one refuses (the older proceeds)" {
  gh_runs 100 123 "${GOOD_SHA}0000000000000000000000000000"
  GITHUB_RUN_ID=200 QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [[ "$output" == *"DEDUP-REFUSED duplicate"* ]]
  [ ! -s "$STUB_CALLS" ]
  gh_runs 300 123 "${GOOD_SHA}0000000000000000000000000000"
  GITHUB_RUN_ID=200 QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "dedup: a NEWER sha already queued for the same PR -> this older sha is refused as superseded" {
  gh_runs 300 123 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  GITHUB_RUN_ID=200 QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEDUP-REFUSED superseded"* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "dedup: an OLDER sha queued for the same PR does not block the newer one" {
  gh_runs 100 123 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  GITHUB_RUN_ID=200 QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "dedup: different PR or different repo never matches" {
  gh_runs 100 999 "${GOOD_SHA}0000000000000000000000000000"
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "dedup: same PR number and sha under ANOTHER repo never matches (PR numbers collide across repos)" {
  gh_runs 100 123 "$GOOD_SHA" queued Muso-AI/other
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "dedup: a run older than the 4h window is not in flight -> dispatches (a wedged queued run cannot block a re-send forever)" {
  gh_runs 100 123 "$GOOD_SHA" queued Muso-AI/hydra 18000
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "dedup: a run inside the 4h window still refuses (window test is not vacuous)" {
  gh_runs 100 123 "$GOOD_SHA" queued Muso-AI/hydra 3600
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [[ "$output" == *"DEDUP-REFUSED duplicate"* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "dedup: a malformed QA_DEDUP_WINDOW_SECONDS falls back to the default window, never aborts dispatch" {
  gh_runs 100 999 "$GOOD_SHA"
  QA_DEDUP_WINDOW_SECONDS=oops QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "dedup: a malformed window still refuses an in-flight duplicate (default window applies)" {
  gh_runs 100 123 "$GOOD_SHA" queued Muso-AI/hydra 3600
  QA_DEDUP_WINDOW_SECONDS=oops QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [[ "$output" == *"DEDUP-REFUSED duplicate"* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "dedup: a leading-zero window (08) is read as decimal, not octal -> still refuses an in-flight duplicate" {
  gh_runs 100 123 "$GOOD_SHA" queued Muso-AI/hydra 2
  QA_DEDUP_WINDOW_SECONDS=08 QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [[ "$output" != *"value too great for base"* ]]
  [[ "$output" != *"DEDUP-SKIPPED"* ]]
  [[ "$output" == *"DEDUP-REFUSED duplicate"* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "dedup: QA_DEDUP_REFUSED_RC=76 (the reconciler) makes a refusal exit 76, still no cron add" {
  gh_runs 100 123 "$GOOD_SHA"
  QA_DEDUP_REFUSED_RC=76 QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 76 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "dedup: fresh (repo,pr,sha) with no runs dispatches" {
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

@test "dedup: lookup FAILS -> fail OPEN, dispatches anyway, says so" {
  STUB_GH_FAIL=1 QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
  [[ "$output" == *"DEDUP-SKIPPED"* ]]
}

@test "dedup: lookup returns garbage -> fail OPEN, dispatches anyway" {
  echo "not json" > "$TEST_TMPDIR/gh.json"; export STUB_GH_JSON="$TEST_TMPDIR/gh.json"
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
}

# --- hydra's own path: qa-autoreview.yml calls this same script (MUS-7955 bot round) ---
AUTOREVIEW="$HYDRA_REPO/.github/workflows/qa-autoreview.yml"

# The run-name carries a TERNARY per field (workflow_dispatch -> inputs, else workflow_run), so a
# renderer must resolve BOTH event shapes. Rendering only the workflow_run form leaves `${{` in the
# name and the guard never matches (QA #1812 r4).
render_run_name() {  # <event: dispatch|workflow_run> <pr> <sha>
  local rn name
  rn="$(grep -m1 '^run-name:' "$AUTOREVIEW")"
  [ -n "$rn" ] || return 1
  name="$(printf '%s' "${rn#run-name: }" | tr -d '"' \
    | sed -e 's/\${{ github.repository }}/Muso-AI\/hydra/')"
  if [ "$1" = "dispatch" ]; then
    # `A && B || C` with A true resolves to B.
    name="$(printf '%s' "$name" \
      | sed -e "s/\${{ github.event_name == 'workflow_dispatch' && inputs.pr || github.event.workflow_run.pull_requests\[0\].number }}/$2/" \
            -e "s/\${{ github.event_name == 'workflow_dispatch' && inputs.sha || github.event.workflow_run.head_sha }}/$3/")"
  else
    # `A && B || C` with A false resolves to C.
    name="$(printf '%s' "$name" \
      | sed -e "s/\${{ github.event_name == 'workflow_dispatch' && inputs.pr || github.event.workflow_run.pull_requests\[0\].number }}/$2/" \
            -e "s/\${{ github.event_name == 'workflow_dispatch' && inputs.sha || github.event.workflow_run.head_sha }}/$3/")"
  fi
  printf '%s' "$name"
}

@test "dedup: qa-autoreview.yml's run-name, rendered, is a name the guard matches -> second hydra dispatch refused" {
  name="$(render_run_name workflow_run 123 "${GOOD_SHA}0000000000000000000000000000")"
  [[ "$name" != *'${{'* ]]
  printf '[{"databaseId":100,"name":"%s","status":"queued","createdAt":"%s"}]\n' "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TEST_TMPDIR/gh.json"
  export STUB_GH_JSON="$TEST_TMPDIR/gh.json"
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [[ "$output" == *"DEDUP-REFUSED duplicate"* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "dedup: the run-name renders for BOTH event shapes, and they differ" {
  # A manual re-dispatch must produce a name the guard can match too, or a re-dispatch of a head
  # that is already queued would add a second cron job for the same review.
  wr="$(render_run_name workflow_run 123 "${GOOD_SHA}0000000000000000000000000000")"
  md="$(render_run_name dispatch 123 "${GOOD_SHA}0000000000000000000000000000")"
  [[ "$wr" != *'${{'* ]]
  [[ "$md" != *'${{'* ]]
  [ "$wr" = "$md" ]
  [[ "$wr" == *"Muso-AI/hydra#123"* ]]
}

@test "dedup: qa-autoreview.yml grants actions: read at workflow level (gh run list 403s without it -> silent DEDUP-SKIPPED)" {
  awk '/^permissions:/{p=1;next} /^[^ #]/{p=0} p' "$AUTOREVIEW" | grep -qE '^  actions: read$'
}

# ── node8-to-pods T9 (2026-10-28): the remote qa-review-gateway target ─────────
t9_env_recorder() {
  # Wrap the stub so every openclaw call also records the gateway env it saw.
  mv "$STUBBIN/openclaw" "$STUBBIN/openclaw.inner"
  export STUB_ENV="$TEST_TMPDIR/env"; : > "$STUB_ENV"
  cat > "$STUBBIN/openclaw" <<'STUB'
#!/usr/bin/env bash
printf 'url=%s token=%s port=%s\n' "${OPENCLAW_GATEWAY_URL:-}" "${OPENCLAW_GATEWAY_TOKEN:-}" "${OPENCLAW_GATEWAY_PORT:-}" >> "$STUB_ENV"
exec "$(dirname "$0")/openclaw.inner" "$@"
STUB
  chmod +x "$STUBBIN/openclaw"
}
T9_URL="ws://qa-review-gateway.hydra-qa.svc.cluster.local:18789"

@test "T9 default (URL unset): unchanged -- local --profile main on every call, no gateway env" {
  t9_env_recorder
  QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
  [ "$(grep -cx -- '--profile' "$STUB_ARGV")" -eq "$(wc -l < "$STUB_ENV" | tr -d ' ')" ]
  ! grep -qv '^url= token=' "$STUB_ENV"
  [[ "$output" == *"(local profile main)"* ]]
}

@test "T9 remote: URL + token file -> every call targets the pod with the token in ENV, never argv, no --profile" {
  t9_env_recorder
  printf 'tok-abc-123\n' > "$TEST_TMPDIR/tok"
  OPENCLAW_GATEWAY_URL="$T9_URL" OPENCLAW_GATEWAY_TOKEN_FILE="$TEST_TMPDIR/tok" OPENCLAW_GATEWAY_PORT=9999 \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
  ! grep -qx -- '--profile' "$STUB_ARGV"
  ! grep -q 'tok-abc-123' "$STUB_ARGV"
  ! grep -qx -- '--token' "$STUB_ARGV"
  [ "$(grep -c "^url=${T9_URL} token=tok-abc-123 port=\$" "$STUB_ENV")" -eq "$(wc -l < "$STUB_ENV" | tr -d ' ')" ]
  grep -qx 'qa' "$STUB_ARGV"
  grep -qx 'qa-autoreview-pr-Muso-AI-hydra-123' "$STUB_ARGV"
  [[ "$output" == *"(remote ${T9_URL})"* ]]
  [[ "$output" != *"tok-abc-123"* ]]
}

@test "T9 remote: OPENCLAW_GATEWAY_TOKEN in env works too" {
  t9_env_recorder
  OPENCLAW_GATEWAY_URL="$T9_URL" OPENCLAW_GATEWAY_TOKEN="tok-env" \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  grep -q "^url=${T9_URL} token=tok-env " "$STUB_ENV"
}

@test "T9 remote: URL without a token refuses (exit 2) BEFORE any openclaw call" {
  OPENCLAW_GATEWAY_URL="$T9_URL" QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_ARGV" ]
  [[ "$output" == *"no token"* ]]
}

@test "T9 remote: unreadable token file / empty token file refuse (exit 2), no call" {
  OPENCLAW_GATEWAY_URL="$T9_URL" OPENCLAW_GATEWAY_TOKEN_FILE="$TEST_TMPDIR/absent" \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 2 ]
  : > "$TEST_TMPDIR/empty"
  OPENCLAW_GATEWAY_URL="$T9_URL" OPENCLAW_GATEWAY_TOKEN_FILE="$TEST_TMPDIR/empty" \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_ARGV" ]
}

@test "T9 remote: a malformed URL refuses (exit 2), no call" {
  for bad in "http://x:1" "ws://" "ws://host/path?x=1" "ws://a b" "ws://-bad:1"; do
    OPENCLAW_GATEWAY_URL="$bad" OPENCLAW_GATEWAY_TOKEN=t QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
    [ "$status" -eq 2 ] || { echo "accepted: $bad"; return 1; }
  done
  [ ! -s "$STUB_ARGV" ]
}

@test "T9 remote: a DNS failure to the pod Service is a transport failure -> exit 75 (not an attempt)" {
  for sig in "getaddrinfo ENOTFOUND qa-review-gateway.hydra-qa.svc.cluster.local" "connect EHOSTUNREACH 10.43.1.2:18789" "getaddrinfo EAI_AGAIN x"; do
    : > "$STUB_CALLS"
    STUB_ADD_ERR="$sig" STUB_ADD_RC=1 OPENCLAW_GATEWAY_URL="$T9_URL" OPENCLAW_GATEWAY_TOKEN=t \
      QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
    [ "$status" -eq 75 ] || { echo "rc=$status for: $sig"; return 1; }
  done
}

@test "T9 remote: a gateway auth rejection keeps openclaw's rc (it reached the pod: a real attempt)" {
  STUB_ADD_ERR="gateway closed (1008): unauthorized" STUB_ADD_RC=1 OPENCLAW_GATEWAY_URL="$T9_URL" OPENCLAW_GATEWAY_TOKEN=wrong \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 1 ]
}

# --- 2026-10-28 (hydra#1456, run 40787678249): one sha, many open PRs -------------------
# Executes the SHIPPED jq filter from qa-autoreview.yml against the real shape of
# GET /repos/Muso-AI/hydra/commits/497b7fcc/pulls (8 open PRs: 7 stacked on fm/ branches,
# one on main). The old filter took the first open PR (#1409, base fm/...), skipped it as
# "not main", and the gated PR #1456 was never reviewed.
autoreview_pr_filter() {
  python3 - "$AUTOREVIEW" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'commits/\$\{HEAD_SHA\}/pulls" \\\s*\n\s*--jq \'([^\']+)\'', s)
if not m:
    sys.exit("jq filter not found in qa-autoreview.yml")
print(m.group(1))
PY
}
STACK_PULLS='[
 {"number":1409,"state":"open","base":{"ref":"fm/verify-ask-wiring-h2-comm-state"}},
 {"number":1418,"state":"open","base":{"ref":"fm/verify-ask-wiring-h2-s1-sender"}},
 {"number":1424,"state":"open","base":{"ref":"fm/verify-ask-wiring-h2-owing-proof"}},
 {"number":1456,"state":"open","base":{"ref":"main"}},
 {"number":1459,"state":"open","base":{"ref":"fm/verify-ask-wiring-h2-merge-pending"}},
 {"number":1400,"state":"closed","base":{"ref":"main"}}]'

@test "autoreview PR resolution: a sha shared by a stack resolves to the main-based PR (#1456), not the first (#1409)" {
  f="$(autoreview_pr_filter)"
  [ -n "$f" ]
  [ "$(jq -r "$f | .number" <<< "$STACK_PULLS")" = "1456" ]
}

@test "autoreview PR resolution: no main-based PR -> first open PR (unchanged skip/pending path); closed main PR ignored; none -> empty" {
  f="$(autoreview_pr_filter)"
  [ "$(jq -r "$f | .number" <<< '[{"number":7,"state":"closed","base":{"ref":"main"}},{"number":8,"state":"open","base":{"ref":"fm/x"}},{"number":9,"state":"open","base":{"ref":"fm/y"}}]')" = "8" ]
  [ -z "$(jq -r "$f" <<< '[{"number":7,"state":"closed","base":{"ref":"main"}}]')" ]
  [ -z "$(jq -r "$f" <<< '[]')" ]
}

@test "autoreview PR resolution mutation: the old first-open-PR filter picks #1409 (the regression this guards)" {
  [ "$(jq -r '[.[] | select(.state=="open")][0] // empty | .number' <<< "$STACK_PULLS")" = "1409" ]
}

# ── broker mode (review-bot findings, 2026-11-06) ─────────────────────────
# The first cut of broker mode referenced $broker_err before assigning it (the
# script runs under `set -u`, so every broker dispatch aborted) and wrote a
# node-local SQLite file while the workers claim from the broker pod's own
# database (so a dispatch returned 0 and no review ever ran). Both are pinned
# here.

@test "broker mode: a local-CLI enqueue does not abort on an unbound broker_err" {
  # QA_BROKER_URL=cli keeps the queue in this process's file, which is what the
  # tests and a single-host deployment use.
  export QA_BROKER_URL=cli
  export QA_QUEUE_DB="$TEST_TMPDIR/queue.sqlite"
  QA_DISPATCH_MODE=broker QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enqueued Muso-AI/hydra#123"* ]]
  # Nothing reached the gateway: broker mode never mints a cron job.
  [ "$(grep -c '^cron-add$' "$STUB_CALLS" || true)" -eq 0 ]
  python3 -c "
import sqlite3,sys
c=sqlite3.connect('$TEST_TMPDIR/queue.sqlite')
r=c.execute('SELECT repo,pr,status FROM jobs').fetchall()
assert r==[('Muso-AI/hydra',123,'queued')], r
c.close()"
}

@test "broker mode: a duplicate enqueue exits 76 without a cron add" {
  export QA_BROKER_URL=cli
  export QA_QUEUE_DB="$TEST_TMPDIR/queue.sqlite"
  QA_DISPATCH_MODE=broker QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  QA_DISPATCH_MODE=broker QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 76 ]
  [[ "$output" == *"DEDUP-REFUSED"* ]]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS" || true)" -eq 0 ]
}

@test "broker mode: an unreachable broker exits 75 (a transport failure, not an attempt)" {
  export QA_BROKER_URL="http://127.0.0.1:1"
  QA_DISPATCH_MODE=broker QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 75 ]
  [[ "$output" == *"BROKER-UNAVAILABLE"* ]]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS" || true)" -eq 0 ]
}

@test "broker mode: an http broker is POSTed to, not written to a local file" {
  # The queue lives in the broker pod's database. A dispatcher that wrote a
  # local SQLite file would return 0 while the broker's queue stayed empty.
  local port=$(( 20000 + RANDOM % 20000 ))
  # The broker refuses mutations without a token; this test is about the
  # transport, not the auth gate (which has its own cases in qa-broker.bats).
  QA_BROKER_ALLOW_UNAUTHENTICATED=1 \
    python3 "$HYDRA_REPO/scripts/lib/qa_broker.py" --db "$TEST_TMPDIR/broker.sqlite" \
    serve --host 127.0.0.1 --port "$port" >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  QA_BROKER_URL="http://127.0.0.1:$port" QA_DISPATCH_MODE=broker \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  local rc=$status out="$output"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 0 ]
  [[ "$out" == *"enqueued Muso-AI/hydra#123"* ]]
  # The job is in the BROKER's database, which is the only one that matters.
  python3 -c "
import sqlite3
c=sqlite3.connect('$TEST_TMPDIR/broker.sqlite')
r=c.execute('SELECT repo,pr,status FROM jobs').fetchall()
assert r==[('Muso-AI/hydra',123,'queued')], r
c.close()"
  # And no local queue file was created.
  [ ! -e "$TEST_TMPDIR/queue.sqlite" ]
}

@test "broker mode: a stale head is not queued at all (STALE-HEAD, exit 0)" {
  # A delayed dispatch for an OLDER head must not reach the queue: the broker
  # cannot see GitHub, so if it arrived it would supersede the current head's
  # queued review and leave the PR's real head unreviewed.
  export QA_BROKER_URL=cli
  export QA_QUEUE_DB="$TEST_TMPDIR/queue.sqlite"
  export STUB_HEAD_SHA="$(printf '%040d' 999)"
  QA_DISPATCH_MODE=broker QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE-HEAD"* ]]
  [[ "$output" != *"enqueued"* ]]
  # Nothing was written to the queue.
  [ ! -e "$TEST_TMPDIR/queue.sqlite" ] || \
    [ "$(python3 -c "
import sqlite3
c=sqlite3.connect('$TEST_TMPDIR/queue.sqlite')
print(c.execute('SELECT COUNT(*) FROM jobs').fetchone()[0])")" -eq 0 ]
}

@test "broker mode: a current head is enqueued WITH supersede rights" {
  export QA_BROKER_URL=cli
  export QA_QUEUE_DB="$TEST_TMPDIR/queue.sqlite"
  export STUB_HEAD_SHA="$GOOD_SHA"
  QA_DISPATCH_MODE=broker QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enqueued Muso-AI/hydra#123"* ]]
  # A second, different head for the same PR supersedes the first: the producer
  # asserted it is the current head, so the broker is allowed to cancel.
  export STUB_HEAD_SHA="$(printf '%040d' 7)"
  # A strictly later verification token: equal tokens do NOT supersede, which
  # is what makes the check-then-act race safe.
  export STUB_HEAD_ORDER="2026-11-06T00:05:00Z"
  QA_DISPATCH_MODE=broker QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$(printf '%040d' 7)"
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3
c=sqlite3.connect('$TEST_TMPDIR/queue.sqlite')
rows=c.execute('SELECT head_sha,status FROM jobs ORDER BY id').fetchall()
assert rows[0][1]=='superseded', rows
assert rows[1][1]=='queued', rows
c.close()"
}

@test "broker mode: a failed head lookup still enqueues, without supersede rights" {
  # Fail safe: an unverifiable head must not block the review, and must not
  # grant the right to cancel someone else's.
  export QA_BROKER_URL=cli
  export QA_QUEUE_DB="$TEST_TMPDIR/queue.sqlite"
  unset STUB_HEAD_SHA
  QA_DISPATCH_MODE=broker QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enqueued Muso-AI/hydra#123"* ]]
  [[ "$output" == *"head lookup failed"* ]]
  QA_DISPATCH_MODE=broker QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$(printf '%040d' 7)"
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3
c=sqlite3.connect('$TEST_TMPDIR/queue.sqlite')
rows=c.execute('SELECT status FROM jobs ORDER BY id').fetchall()
assert [r[0] for r in rows]==['queued','queued'], rows
c.close()"
}

@test "broker mode: a 502 with a JSON body and no rc is a transport failure, not an enqueue" {
  # A proxy or a half-up broker can answer 502 with a JSON error body. curl
  # exits 0, and a missing `rc` used to default to 0, so the dispatcher reported
  # "enqueued" for a row that does not exist: the reconciler treats the review
  # as dispatched and the PR never gets a verdict.
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 - "$port" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = b'{"error":"upstream unavailable"}'
        self.send_response(502)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
    sleep 0.1
  done
  QA_BROKER_URL="http://127.0.0.1:$port" QA_DISPATCH_MODE=broker \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  local rc=$status out="$output"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 75 ]
  [[ "$out" == *"BROKER-UNAVAILABLE"* ]]
  [[ "$out" != *"enqueued"* ]]
}

@test "broker mode: a 200 with no rc in the body is a transport failure" {
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 - "$port" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
    sleep 0.1
  done
  QA_BROKER_URL="http://127.0.0.1:$port" QA_DISPATCH_MODE=broker \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  local rc=$status out="$output"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 75 ]
  [[ "$out" != *"enqueued"* ]]
}

@test "broker mode: a 409 duplicate is deduped (76), not a transport failure" {
  # The broker's contract uses the HTTP status to carry meaning: a duplicate is
  # 409 with rc 76 in the body. Requiring 2xx here turned every repeat dispatch
  # into "broker unavailable" (75), which the reconciler then retried forever.
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 - "$port" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = b'{"ok":false,"status":"duplicate","rc":76}'
        self.send_response(409)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
    sleep 0.1
  done
  QA_BROKER_URL="http://127.0.0.1:$port" QA_DISPATCH_MODE=broker \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  local rc=$status out="$output"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 76 ]
  [[ "$out" != *"BROKER-UNAVAILABLE"* ]]
}

@test "broker mode: no temp file is leaked on any exit path" {
  # The EXIT trap used to be installed ~320 lines below the broker branch, so
  # every broker dispatch created its stderr temp file and exited before the
  # trap existed. A dispatcher runs on every PR push, so that is an unbounded
  # leak in /tmp on the runner. TMPDIR is redirected so the count is exact.
  local tmpd="$TEST_TMPDIR/leakcheck"
  mkdir -p "$tmpd"
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 - "$port" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = b'{"ok":true,"status":"queued","id":1,"rc":0}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
    sleep 0.1
  done
  TMPDIR="$tmpd" QA_BROKER_URL="http://127.0.0.1:$port" QA_DISPATCH_MODE=broker \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  local rc=$status
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 0 ]
  # Nothing left behind: the trap removed the stderr file it created.
  run bash -c "ls -A '$tmpd' | wc -l"
  [ "$output" -eq 0 ]
}

@test "broker mode: a 500 with rc 3 is reported as an internal error, not a dedupe" {
  # An explicit rc is authoritative whatever the status, so the broker's own
  # 500+rc:3 (up but broken) must not be flattened into 75 or 76.
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 - "$port" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = b'{"ok":false,"error":"OperationalError","rc":3}'
        self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
    sleep 0.1
  done
  QA_BROKER_URL="http://127.0.0.1:$port" QA_DISPATCH_MODE=broker \
    QA_REVIEW_REQUESTER_UID="$NICK" run "$SCRIPT" 123 "$GOOD_SHA"
  local rc=$status out="$output"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$rc" -ne 0 ]
  [ "$rc" -ne 76 ]
  [[ "$out" != *"enqueued"* ]]
}

# --- 2026-11-06 (hydra#1820 @ 086158df, run 42282917209): a failed dispatch must be ---
# --- visible ON THE PR even on an ungated repo -------------------------------------
# Executes the SHIPPED step script from qa-autoreview.yml in a scratch checkout where
# gh, the dispatcher and the status writer are stubs. The scratch policy is written
# explicitly with .merge_gate_repos empty, so these tests pin the UNGATED step behavior
# they claim to and do not move when hydra is added to the live gate list. Ungated is
# the shape that mattered: before this fix the dispatch-failure say_status posted
# NOTHING and the red workflow_run (not attached to the PR's checks) was the only trace.
autoreview_step_script() {
  python3 - "$AUTOREVIEW" <<'PY'
import yaml, sys
wf = yaml.safe_load(open(sys.argv[1]))
steps = wf["jobs"]["dispatch"]["steps"]
step = [s for s in steps if s.get("name", "").startswith("Resolve PR")][0]
print(step["run"])
PY
}
autoreview_scratch() {   # <dispatcher-rc> -> scratch checkout dir with stubs
  local d="$TEST_TMPDIR/autoreview"; mkdir -p "$d/scripts/lib" "$d/policies"
  cp "$HYDRA_REPO/scripts/lib/qa-policy.sh" "$HYDRA_REPO/scripts/lib/qa-author-slack-uid.sh" "$d/scripts/lib/"
  printf '{"merge_gate_repos":[],"identity":{"app_repos":[]}}\n' > "$d/policies/qa-approval-policy.json"
  printf '#!/usr/bin/env bash\necho "dispatch $*" >> "%s/calls"\nexit %s\n' "$d" "$1" > "$d/scripts/qa-dispatch-pr-review.sh"
  printf '#!/usr/bin/env bash\necho "status $*" >> "%s/calls"\n' "$d" > "$d/scripts/qa-review-status.sh"
  # gh stub: the PR lookup for the head (one open main-based PR by adk47), plus the
  # manual-dispatch lookup `repos/<repo>/pulls/<n>`. STUB_PULLS lists the PR numbers that
  # are OPEN; STUB_PULL_HEAD is the head sha they report. Anything else 404s, which is what
  # the step's `|| true` is there for.
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/Muso-AI/hydra/commits/"*) echo '{"number":1820,"user":{"login":"adk47"},"draft":false,"base":{"ref":"main"}}' ;;
  "api repos/Muso-AI/hydra/pulls/"*)
    n="${2##*/}"
    if [ -n "${STUB_PULLS:-}" ] && printf '%s\n' $STUB_PULLS | grep -qx "$n"; then
      printf '{"number":%s,"state":"open","head":{"sha":"%s"},"user":{"login":"adk47"},"draft":false,"base":{"ref":"main"}}\n' \
        "$n" "${STUB_PULL_HEAD:-086158dfc76ea0be043d3a7fb95b92ea5f240947}"
    else
      echo '{"message":"Not Found"}' >&2; exit 1
    fi ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$STUBBIN/gh"
  autoreview_step_script > "$d/step.sh"
  echo "$d"
}
# EVENT_NAME and INPUT_PR are step env in the workflow, so the harness must supply them or
# the step aborts under `set -u` before it reaches any stub (QA #1812 r4). The default is the
# automatic workflow_run shape, which is what every pre-existing test here exercises.
autoreview_run_step() {   # <dir> [event] [input-pr]
  local ev="${2:-workflow_run}" ipr="${3:-}"
  ( cd "$1" && REPO=Muso-AI/hydra HEAD_SHA=086158dfc76ea0be043d3a7fb95b92ea5f240947 \
      EVENT_NAME="$ev" INPUT_PR="$ipr" \
      GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=42282917209 bash step.sh )
}

@test "autoreview step: dispatcher exit 75 on an ungated repo -> red step, ::error names the reason, qa-review=failure IS posted" {
  d="$(autoreview_scratch 75)"
  run autoreview_run_step "$d"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::NO QA REVIEW QUEUED for PR #1820 @ 086158d: gateway unreachable; review not confirmed queued."* ]]
  [[ "$output" == *"actions/runs/42282917209"* ]]
  grep -q '^dispatch 1820 086158dfc76ea0be043d3a7fb95b92ea5f240947 Muso-AI/hydra U7RP6HKUZ$' "$d/calls"
  grep -q '^status Muso-AI/hydra 086158dfc76ea0be043d3a7fb95b92ea5f240947 failure QA review could not be dispatched — gateway unreachable; review not confirmed queued (run 42282917209)$' "$d/calls"
  # The gated pending stays gated: the only status written off the gate is the failure.
  [ "$(grep -c '^status ' "$d/calls")" -eq 1 ]
}

@test "autoreview step: a non-75 dispatcher failure is red and posted too, with the rc named" {
  d="$(autoreview_scratch 1)"
  run autoreview_run_step "$d"
  [ "$status" -eq 1 ]
  grep -q '^status .* failure QA review could not be dispatched — dispatcher exited 1 (run 42282917209)$' "$d/calls"
}

@test "autoreview step: a successful dispatch on an ungated repo posts NO status (nothing changes on the happy path)" {
  d="$(autoreview_scratch 0)"
  run autoreview_run_step "$d"
  [ "$status" -eq 0 ]
  grep -q '^dispatch 1820 ' "$d/calls"
  ! grep -q '^status ' "$d/calls"
}

@test "autoreview step: the dispatch-failure description is classified by the reconciler as infrastructure, not a verdict" {
  # The posted description must START with the QAR_INFRA_STATUS_MARKERS prefix so the
  # reconciler re-dispatches instead of parking the head as "reviewed".
  d="$(autoreview_scratch 75)"
  autoreview_run_step "$d" >/dev/null 2>&1 || true
  desc="$(sed -n 's/^status Muso-AI\/hydra [0-9a-f]* failure //p' "$d/calls")"
  [ -n "$desc" ]
  source "$HYDRA_REPO/scripts/lib/qa-reconcile.sh"
  [ "$(qar_classify_verdict 0 failure 0 "$desc")" = "candidate" ]
}

# --- 2026-11-07 (hydra#1812 r4): the MANUAL re-dispatch paths, executed ---------------
# The schema suite pins the workflow's shape; these run the shipped step script so the
# refusal paths are proven end to end, including WHICH commit a refusal lands on. That
# target is the whole point: a refusal posted to the wrong sha either hides the refusal
# from the PR the operator asked about, or marks an unrelated PR red.
@test "autoreview step (manual): a current head proceeds and posts no status on an ungated repo" {
  d="$(autoreview_scratch 0)"
  STUB_PULLS=1820 autoreview_run_step "$d" workflow_dispatch 1820 >"$d/out" 2>&1
  grep -q 'Manual re-dispatch: PR #1820 @ 086158d is still the current head — proceeding.' "$d/out"
  grep -q '^dispatch 1820 086158dfc76ea0be043d3a7fb95b92ea5f240947 Muso-AI/hydra U7RP6HKUZ$' "$d/calls"
  ! grep -q '^status ' "$d/calls"
}

@test "autoreview step (manual): a head-moved refusal lands on the PR's LIVE head, not the typed sha" {
  d="$(autoreview_scratch 0)"
  # The PR's head has moved on; the operator typed the superseded sha.
  rc=0
  STUB_PULLS=1820 STUB_PULL_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
    autoreview_run_step "$d" workflow_dispatch 1820 >"$d/out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
  grep -q '::error::PR #1820 head is now deadbee, not 086158d — refusing to review a superseded commit.' "$d/out"
  # The refusal is on the LIVE head...
  grep -q '^status Muso-AI/hydra deadbeefdeadbeefdeadbeefdeadbeefdeadbeef failure re-dispatch refused: PR #1820 head moved to deadbee$' "$d/calls"
  # ...and NOT on the sha the operator typed, which is what QA #1812 finding 1 was about.
  # A bare `! grep` is not enough: bats takes the test result from the LAST command, so a regression here would
  # fail this line and still report green off the next one (QA #1812 r5). Each negative is fatal on its own.
  if grep -q '^status Muso-AI/hydra 086158dfc76ea0be043d3a7fb95b92ea5f240947 ' "$d/calls"; then
    echo "a refusal was posted on the superseded sha the operator typed:"; cat "$d/calls"; false
  fi
  if grep -q '^dispatch ' "$d/calls"; then
    echo "a superseded head was dispatched anyway:"; cat "$d/calls"; false
  fi
}

@test "autoreview step (manual): a not-open PR posts NO status at all, so it cannot mark another PR red" {
  d="$(autoreview_scratch 0)"
  # PR 9999 is not open; the typed sha is the current head of open PR 1820.
  rc=0
  STUB_PULLS=1820 autoreview_run_step "$d" workflow_dispatch 9999 >"$d/out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
  grep -q '::error::re-dispatch asked for PR #9999, which is not an open PR — refusing. No status was posted' "$d/out"
  # No status on ANY sha: the only sha we hold is the one the operator typed. Fatal on its own, for the reason
  # above: a `! grep` followed by another command cannot fail the test.
  if grep -q '^status ' "$d/calls"; then
    echo "a not-open refusal posted a status, which can mark another PR red:"; cat "$d/calls"; false
  fi
  if grep -q '^dispatch ' "$d/calls"; then
    echo "a not-open PR was dispatched anyway:"; cat "$d/calls"; false
  fi
}
