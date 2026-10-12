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
    if [ -n "${STUB_ADD_ERR:-}" ]; then echo "$STUB_ADD_ERR" >&2; fi
    if [ -n "${STUB_ADD_RC:-}" ]; then exit "$STUB_ADD_RC"; fi
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
if [ -f "${STUB_GH_JSON:-}" ]; then cat "$STUB_GH_JSON"; else echo '[]'; fi
STUB
  chmod +x "$STUBBIN/gh"
  export STUB_GH_ARGV="$TEST_TMPDIR/gh_argv"; : > "$STUB_GH_ARGV"
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
