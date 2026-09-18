#!/usr/bin/env bats
# Tests for scripts/qa-review-reconcile.sh (the QA auto-review reconciler)
# and its pure decision library scripts/lib/qa-reconcile.sh.
#
# Section 1 tests the pure lib directly (no stubbing needed — fast, exact).
# Section 2 runs the full entrypoint against PATH-shadowed stubs for gh,
# openclaw, muso (Slack), and the qa-*.sh actuator/lookup scripts, so the
# suite NEVER touches a live gateway, GitHub, or Slack (memory: an unstubbed
# test once fired 9 real Slack alerts to prod).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/qa-reconcile.sh"
SCRIPT="$HYDRA_REPO/scripts/qa-review-reconcile.sh"

# ─────────────────────────────────────────────────────────────────────────
# Section 1: pure lib
# ─────────────────────────────────────────────────────────────────────────

setup_lib() {
  # shellcheck source=../lib/qa-reconcile.sh
  source "$LIB"
}

@test "lib: qar_repo_gated_base — hydra only gates main" {
  setup_lib
  run qar_repo_gated_base "Muso-AI/hydra" "main"
  [ "$status" -eq 0 ]
  run qar_repo_gated_base "Muso-AI/hydra" "develop"
  [ "$status" -ne 0 ]
}

@test "lib: qar_repo_gated_base — external repos gate develop/main/master" {
  setup_lib
  run qar_repo_gated_base "Muso-AI/core-backend" "develop"
  [ "$status" -eq 0 ]
  run qar_repo_gated_base "Muso-AI/core-backend" "master"
  [ "$status" -eq 0 ]
  run qar_repo_gated_base "Muso-AI/core-backend" "feature/x"
  [ "$status" -ne 0 ]
}

@test "lib: qar_bot_logins — refuses (rc1) on missing/malformed policy, no default" {
  setup_lib
  run qar_bot_logins "/nonexistent/policy.json"
  [ "$status" -eq 1 ]

  bad="$BATS_TEST_TMPDIR/bad.json"
  echo '{"identity": {}}' > "$bad"
  run qar_bot_logins "$bad"
  [ "$status" -eq 1 ]
}

@test "lib: qar_has_bot_review — literal equality, NOT regex (muso-qa-bot[bot] is a valid login, not a character class)" {
  setup_lib
  reviews='[{"commit_id":"deadbeef","user":{"login":"muso-qa-bot[bot]"}}]'
  bots='["muso-qa-bot","muso-qa-bot[bot]","adk47"]'
  run qar_has_bot_review "$reviews" "deadbeef" "$bots"
  [ "$status" -eq 0 ]
}

@test "lib: qar_has_bot_review — a login that would match the [bot] CHARACTER CLASS under test() must NOT match" {
  setup_lib
  # "muso-qa-boo" would match jq's test("muso-qa-bot[bot]") because [bot] is a
  # regex character class matching one of b/o/t — this is the exact bug the
  # coordinator's rehearsal caught. Literal index() must reject it.
  reviews='[{"commit_id":"deadbeef","user":{"login":"muso-qa-boo"}}]'
  bots='["muso-qa-bot","muso-qa-bot[bot]","adk47"]'
  run qar_has_bot_review "$reviews" "deadbeef" "$bots"
  [ "$status" -ne 0 ]
}

@test "lib: qar_has_bot_review — sha must match exactly (stale review on an old head is not a verdict)" {
  setup_lib
  reviews='[{"commit_id":"oldsha","user":{"login":"muso-qa-bot"}}]'
  bots='["muso-qa-bot"]'
  run qar_has_bot_review "$reviews" "newsha" "$bots"
  [ "$status" -ne 0 ]
}

@test "lib: qar_qa_review_status_state — legitimate absent (no qa-review context) is rc0, not a failure" {
  setup_lib
  run qar_qa_review_status_state '{"statuses":[{"context":"other","state":"success"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "absent" ]
}

@test "lib: qar_qa_review_status_state — finds the qa-review context's state" {
  setup_lib
  run qar_qa_review_status_state '{"statuses":[{"context":"qa-review","state":"failure"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "failure" ]
}

@test "lib: qar_qa_review_status_state — malformed/unparseable input is rc1 (unreadable), NEVER echoed/treated as 'absent'" {
  setup_lib
  run qar_qa_review_status_state 'not json'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "lib: qar_classify_verdict — bot review is a verdict" {
  setup_lib
  run qar_classify_verdict 1 "absent" 0
  [ "$output" = "verdict" ]
}

@test "lib: qar_classify_verdict — terminal status is a verdict" {
  setup_lib
  for s in success failure error; do
    run qar_classify_verdict 0 "$s" 0
    [ "$output" = "verdict" ]
  done
}

@test "lib: qar_classify_verdict — pending on a non-gated repo suppresses (not a verdict, not a candidate)" {
  setup_lib
  run qar_classify_verdict 0 "pending" 0
  [ "$output" = "pending-suppress" ]
}

@test "lib: qar_classify_verdict — pending on a MERGE-GATED repo is a candidate (stale pending must not silence forever)" {
  setup_lib
  run qar_classify_verdict 0 "pending" 1
  [ "$output" = "candidate" ]
}

@test "lib: qar_classify_verdict — nothing found is a candidate" {
  setup_lib
  run qar_classify_verdict 0 "absent" 0
  [ "$output" = "candidate" ]
}

@test "lib: qar_classify_verdict — MERGE-GATED + bot review + pending status is a CANDIDATE, not a verdict" {
  setup_lib
  # The reviewing skill posts its COMMENT review (Step 6) BEFORE it publishes the
  # terminal qa-review status (Step 6b). A gateway death in that window leaves a
  # bot review on the head sha with the required check still `pending`. Calling
  # that a verdict would leave the gate pending forever with the reconciler
  # believing all is well -- and GitHub never times out a required check that was
  # never reported, so the PR is permanently unmergeable, silently.
  run qar_classify_verdict 1 pending 1
  [ "$status" -eq 0 ]
  [ "$output" = "candidate" ]
}

@test "lib: qar_classify_verdict — MERGE-GATED + bot review + NO status is a CANDIDATE" {
  setup_lib
  run qar_classify_verdict 1 absent 1
  [ "$output" = "candidate" ]
}

@test "lib: qar_classify_verdict — MERGE-GATED still accepts a terminal status as the verdict" {
  setup_lib
  run qar_classify_verdict 1 success 1
  [ "$output" = "verdict" ]
  run qar_classify_verdict 0 failure 1
  [ "$output" = "verdict" ]
  run qar_classify_verdict 0 error 1
  [ "$output" = "verdict" ]
}

@test "lib: qar_classify_verdict — UNGATED repo is unchanged: a bot review alone is still a verdict" {
  setup_lib
  # No required check exists on an ungated repo, so the review IS the outcome.
  run qar_classify_verdict 1 pending 0
  [ "$output" = "verdict" ]
  run qar_classify_verdict 1 absent 0
  [ "$output" = "verdict" ]
  run qar_classify_verdict 0 pending 0
  [ "$output" = "pending-suppress" ]
}

@test "lib: qar_cron_state — running/queued/done/absent/unknown, all fresh (within the stale budget)" {
  setup_lib
  now_ms=2000000000000; budget_s=1800  # budget_ms = 1800000
  running_fresh='{"jobs":[{"name":"j","state":{"runningAtMs":1999999000000}}]}'  # 1000s ago
  run qar_cron_state "$running_fresh" "j" "$now_ms" "$budget_s"; [ "$output" = "running" ]

  queued_fresh='{"jobs":[{"name":"j","state":{"nextRunAtMs":1999999000000}}]}'   # 1000s past-due
  run qar_cron_state "$queued_fresh" "j" "$now_ms" "$budget_s"; [ "$output" = "queued" ]

  queued_future='{"jobs":[{"name":"j","state":{"nextRunAtMs":2000001000000}}]}'  # not due yet
  run qar_cron_state "$queued_future" "j" "$now_ms" "$budget_s"; [ "$output" = "queued" ]

  status_running='{"jobs":[{"name":"j","status":"running","state":{}}]}'
  run qar_cron_state "$status_running" "j" "$now_ms" "$budget_s"; [ "$output" = "running" ]

  done_j='{"jobs":[{"name":"j","state":{"lastRunAtMs":1,"lastStatus":"ok"}}]}'
  run qar_cron_state "$done_j" "j" "$now_ms" "$budget_s"; [ "$output" = "done" ]

  absent='{"jobs":[]}'
  run qar_cron_state "$absent" "j" "$now_ms" "$budget_s"; [ "$output" = "absent" ]

  more='{"jobs":[],"hasMore":true}'
  run qar_cron_state "$more" "j" "$now_ms" "$budget_s"; [ "$output" = "unknown" ]
}

@test "lib: qar_cron_state — empty/whitespace input is unknown, not absent (a failed read is not evidence of absence)" {
  setup_lib
  run qar_cron_state "" "j" 2000000000000 1800; [ "$output" = "unknown" ]
  run qar_cron_state "   " "j" 2000000000000 1800; [ "$output" = "unknown" ]
  run qar_cron_state "$(printf ' \t\n ')" "j" 2000000000000 1800; [ "$output" = "unknown" ]
}

@test "lib: qar_cron_state — garbage (unparseable) input is unknown" {
  setup_lib
  run qar_cron_state "not json" "j" 2000000000000 1800; [ "$output" = "unknown" ]
}

@test "lib: qar_cron_state — malformed now_ms/budget args are unknown, not a crash" {
  setup_lib
  running='{"jobs":[{"name":"j","state":{"runningAtMs":1}}]}'
  run qar_cron_state "$running" "j" "not-a-number" 1800; [ "$output" = "unknown" ]
  run qar_cron_state "$running" "j" 2000000000000 "not-a-number"; [ "$output" = "unknown" ]
}

@test "lib: qar_cron_state — running-stale: a killed run's runningAtMs older than the budget does NOT read as in-flight" {
  setup_lib
  now_ms=2000000000000; budget_s=1800  # budget_ms = 1800000
  # exactly at the boundary (elapsed == budget) is still fresh (<=)
  boundary='{"jobs":[{"name":"j","state":{"runningAtMs":1999998200000}}]}'  # elapsed 1800000ms
  run qar_cron_state "$boundary" "j" "$now_ms" "$budget_s"; [ "$output" = "running" ]

  # one ms past the boundary is stale
  stale='{"jobs":[{"name":"j","state":{"runningAtMs":1999998199999}}]}'  # elapsed 1800001ms
  run qar_cron_state "$stale" "j" "$now_ms" "$budget_s"; [ "$output" = "running-stale" ]

  # a long-dead run (e.g. runningAtMs=1, epoch-adjacent) is stale
  ancient='{"jobs":[{"name":"j","state":{"runningAtMs":1}}]}'
  run qar_cron_state "$ancient" "j" "$now_ms" "$budget_s"; [ "$output" = "running-stale" ]
}

@test "lib: qar_cron_state — queued-stale: a past-due, never-fired nextRunAtMs older than the budget does NOT read as in-flight" {
  setup_lib
  now_ms=2000000000000; budget_s=1800  # budget_ms = 1800000
  boundary='{"jobs":[{"name":"j","state":{"nextRunAtMs":1999998200000}}]}'  # past-due by exactly 1800000ms
  run qar_cron_state "$boundary" "j" "$now_ms" "$budget_s"; [ "$output" = "queued" ]

  stale='{"jobs":[{"name":"j","state":{"nextRunAtMs":1999998199999}}]}'  # past-due by 1800001ms
  run qar_cron_state "$stale" "j" "$now_ms" "$budget_s"; [ "$output" = "queued-stale" ]

  # the exact reintroduction scenario: a gateway restart before a one-shot
  # fires, past-due by hours, no lastRunAtMs/runningAtMs anywhere.
  never_fired='{"jobs":[{"name":"j","state":{"nextRunAtMs":1999900000000}}]}'  # past-due ~100000s
  run qar_cron_state "$never_fired" "j" "$now_ms" "$budget_s"; [ "$output" = "queued-stale" ]
}

@test "lib: qar_grace_ok / qar_cooldown_ok / qar_attempts_exhausted" {
  setup_lib
  run qar_grace_ok 2000 100 1800; [ "$status" -eq 0 ]
  run qar_grace_ok 1000 900 1800; [ "$status" -ne 0 ]

  run qar_cooldown_ok 2000 "" 1800; [ "$status" -eq 0 ]
  run qar_cooldown_ok 2000 100 1800; [ "$status" -eq 0 ]
  run qar_cooldown_ok 1000 900 1800; [ "$status" -ne 0 ]

  run qar_attempts_exhausted 2 2; [ "$status" -eq 0 ]
  run qar_attempts_exhausted 1 2; [ "$status" -ne 0 ]
}

@test "lib: qar_read_fail_should_page — due when never paged or interval elapsed, suppressed inside it, and ALWAYS due on garbage or a FUTURE stamp (fail toward paging, never toward silence)" {
  setup_lib
  # Never paged / interval elapsed -> due.
  run qar_read_fail_should_page 0 10000 21600;      [ "$status" -eq 0 ]
  run qar_read_fail_should_page 1000 22600 21600;   [ "$status" -eq 0 ]
  # Inside the window -> suppressed.
  run qar_read_fail_should_page 1000 22599 21600;   [ "$status" -ne 0 ]
  # Garbage stamp -> due (an unreadable stamp must never buy silence).
  run qar_read_fail_should_page "abc" 10000 21600;  [ "$status" -eq 0 ]
  run qar_read_fail_should_page "" 10000 21600;     [ "$status" -eq 0 ]
  # FUTURE stamp (host clock stepped back, or corrupted state) -> due.
  # Without this arm `now - last` is negative, which reads as "inside the
  # window" and suppresses the alert until the future time PLUS the interval —
  # a read outage could stay silent far beyond 6h, which is the exact
  # under-alerting direction this predicate exists to prevent.
  run qar_read_fail_should_page 99999 10000 21600;  [ "$status" -eq 0 ]
  run qar_read_fail_should_page 10001 10000 21600;  [ "$status" -eq 0 ]
}

@test "lib: qar_state_read — missing file is normal first run ('{}', rc 0)" {
  setup_lib
  run qar_state_read "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "lib: qar_state_read — unparseable file refuses (rc 1)" {
  setup_lib
  f="$BATS_TEST_TMPDIR/bad.json"
  echo 'not json' > "$f"
  run qar_state_read "$f"
  [ "$status" -eq 1 ]
}

@test "lib: qar_state_repo_failure_count / qar_state_set_repo_failure_count — round-trip, 0 removes the entry, independent of consecutive_tick_failures" {
  setup_lib
  s='{}'
  run qar_state_repo_failure_count "$s" "Muso-AI/core-backend"
  [ "$output" = "0" ]
  s="$(qar_state_set_repo_failure_count "$s" "Muso-AI/core-backend" 2)"
  run qar_state_repo_failure_count "$s" "Muso-AI/core-backend"
  [ "$output" = "2" ]
  # a different repo's count is independent
  run qar_state_repo_failure_count "$s" "Muso-AI/other-repo"
  [ "$output" = "0" ]
  # setting consecutive_tick_failures must not clobber repo_failures
  s="$(qar_state_set_meta_failures "$s" 5)"
  run qar_state_repo_failure_count "$s" "Muso-AI/core-backend"
  [ "$output" = "2" ]
  [ "$(qar_state_meta_failures "$s")" = "5" ]
  # 0 removes the entry rather than storing an explicit zero
  s="$(qar_state_set_repo_failure_count "$s" "Muso-AI/core-backend" 0)"
  [ "$(jq -r '.__meta__.repo_failures | has("Muso-AI/core-backend")' <<<"$s")" = "false" ]
}

@test "lib: qar_state_put / qar_state_entry round-trip" {
  setup_lib
  s='{}'
  s="$(qar_state_put "$s" "repo#1@sha" 1 100 0)"
  run qar_state_entry "$s" "repo#1@sha"
  [ "$(jq -r '.attempts' <<<"$output")" = "1" ]
}

@test "lib: qar_state_keep_only — prunes closed/superseded keys, preserves reserved keys" {
  setup_lib
  s='{"a#1@x":{"attempts":1},"b#2@y":{"attempts":2},"__meta__":{"consecutive_tick_failures":1},"__repo_epochs__":{"r":1},"__ready_cache__":{"k":1}}'
  s="$(qar_state_keep_only "$s" "a#1@x")"
  [ "$(jq -r 'has("a#1@x")' <<<"$s")" = "true" ]
  [ "$(jq -r 'has("b#2@y")' <<<"$s")" = "false" ]
  [ "$(jq -r 'has("__meta__")' <<<"$s")" = "true" ]
  [ "$(jq -r 'has("__repo_epochs__")' <<<"$s")" = "true" ]
  [ "$(jq -r 'has("__ready_cache__")' <<<"$s")" = "true" ]
}

@test "lib: qar_state_ensure_repo_epochs — mints missing epochs, never overwrites existing" {
  setup_lib
  s='{"__repo_epochs__":{"Muso-AI/hydra":100}}'
  s="$(qar_state_ensure_repo_epochs "$s" "$(printf 'Muso-AI/hydra\nMuso-AI/newrepo\n')" 500)"
  [ "$(jq -r '.__repo_epochs__["Muso-AI/hydra"]' <<<"$s")" = "100" ]
  [ "$(jq -r '.__repo_epochs__["Muso-AI/newrepo"]' <<<"$s")" = "500" ]
}

@test "lib: qar_trigger_in_scope — post-epoch trigger is in scope, pre-epoch is not" {
  setup_lib
  run qar_trigger_in_scope 600 500 1000 1209600
  [ "$status" -eq 0 ]
  run qar_trigger_in_scope 400 500 1000 1209600
  [ "$status" -ne 0 ]
}

@test "lib: qar_trigger_in_scope — a PR older than the 14d ceiling is excluded even when the repo epoch is older still" {
  setup_lib
  now=2000000
  ceiling=1209600
  old_repo_epoch=1
  trigger=$((now - ceiling - 100))  # just past the ceiling
  run qar_trigger_in_scope "$trigger" "$old_repo_epoch" "$now" "$ceiling"
  [ "$status" -ne 0 ]
}

@test "lib: qar_max_epoch — takes the later of head-push and ready_for_review" {
  setup_lib
  run qar_max_epoch 100 200
  [ "$output" = "200" ]
  run qar_max_epoch 300 200
  [ "$output" = "300" ]
  run qar_max_epoch 100 ""
  [ "$output" = "100" ]
}

@test "lib: qar_ready_cache_get/put — cache hit only when updated_at still matches" {
  setup_lib
  s="$(qar_ready_cache_put '{}' "repo" "5" "2026-01-01T00:00:00Z" 555)"
  run qar_ready_cache_get "$s" "repo" "5" "2026-01-01T00:00:00Z"
  [ "$output" = "555" ]
  run qar_ready_cache_get "$s" "repo" "5" "2026-02-01T00:00:00Z"
  [ -z "$output" ]
}

# ── qar_qa_review_rollup_state (2026-09-17 read-amplification cut) ─────────
# The PR list carries each context's LATEST state for the head commit, which
# is the same fact as the per-PR `commits/<sha>/status` read. These pin the
# parse, including the two ways it must NOT answer: a missing context reads
# `absent` (fall through to the reads) and a jq failure is rc 1 (fall through,
# never "no verdict").

@test "lib: qar_qa_review_rollup_state — reads the qa-review context state" {
  setup_lib
  run qar_qa_review_rollup_state '[{"context":"qa-review","state":"success"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
  run qar_qa_review_rollup_state '[{"context":"build","state":"success"},{"context":"qa-review","state":"FAILURE"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "failure" ]
  run qar_qa_review_rollup_state '[{"context":"qa-review","state":"error"}]'
  [ "$output" = "error" ]
  run qar_qa_review_rollup_state '[{"context":"qa-review","state":"pending"}]'
  [ "$output" = "pending" ]
}

@test "lib: qar_qa_review_rollup_state — check-run shape and missing context" {
  setup_lib
  # A CheckRun context (name+conclusion) rather than a StatusContext.
  run qar_qa_review_rollup_state '[{"name":"qa-review","conclusion":"success"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
  run qar_qa_review_rollup_state '[{"context":"other","state":"success"}]'
  [ "$output" = "absent" ]
  run qar_qa_review_rollup_state '[]'
  [ "$output" = "absent" ]
  # Not an array at all (a shape change) reads absent, i.e. fall through to
  # the per-PR reads — the fail-safe direction.
  run qar_qa_review_rollup_state '{"nodes":[]}'
  [ "$output" = "absent" ]
}

@test "lib: qar_qa_review_rollup_state — jq failure is rc 1, never 'absent'" {
  setup_lib
  run qar_qa_review_rollup_state 'not json at all'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ─────────────────────────────────────────────────────────────────────────
# Section 2: full entrypoint, PATH-shadowed
# ─────────────────────────────────────────────────────────────────────────

NOW_EPOCH=2000000000  # fixed "now" for deterministic grace/cooldown/age math

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  FIX="$TEST_TMPDIR/fix"; export FIX; mkdir -p "$FIX/prlist" "$FIX/reviews" "$FIX/status" "$FIX/timeline" "$FIX/commit"

  export DISPATCH_CALLS="$TEST_TMPDIR/dispatch_calls"; : > "$DISPATCH_CALLS"
  export SLACK_CALLS="$TEST_TMPDIR/slack_calls"; : > "$SLACK_CALLS"
  export STATUS_CALLS="$TEST_TMPDIR/status_calls"; : > "$STATUS_CALLS"
  export GH_LOG="$TEST_TMPDIR/gh_log"; : > "$GH_LOG"
  export ROLLUP_SEARCH_CALLS="$TEST_TMPDIR/rollup_search_calls"; : > "$ROLLUP_SEARCH_CALLS"

  # --- gh stub -------------------------------------------------------------
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
key() { printf '%s' "$1" | tr '/' '-'; }

if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  repo=""
  json_arg=""
  search_arg=""
  prev=""
  for a in "$@"; do
    [ "$prev" = "--repo" ] && repo="$a"
    [ "$prev" = "--json" ] && json_arg="$a"
    [ "$prev" = "--search" ] && search_arg="$a"
    prev="$a"
  done
  case "$json_arg" in
    *statusCheckRollup*)
      # ── Rollup enrichment call (best-effort, scoped by --search) ──────
      [ -n "${ROLLUP_SEARCH_CALLS:-}" ] && printf '%s\t%s\n' "$repo" "$search_arg" >> "$ROLLUP_SEARCH_CALLS"
      [ -n "${STUB_ROLLUP_FAIL:-}" ] && exit 1
      [ -n "${STUB_ROLLUP_MALFORMED:-}" ] && { echo '{}'; exit 0; }
      # Default: derive {number, statusCheckRollup} from the same listing
      # fixture the LISTING call below reads, so a test that seeds a rollup
      # by mutating $FIX/prlist/<repo>.json (the pre-existing terminal-skip
      # convention) keeps working unchanged.
      f="$FIX/prlist/$(key "$repo").json"
      if [ -f "$f" ]; then
        jq -c '[.[] | {number: .number, statusCheckRollup: (.statusCheckRollup // [])}]' "$f"
      else
        echo '[]'
      fi
      exit 0
      ;;
  esac
  if [ -n "${STUB_PRLIST_FAIL_REPOS:-}" ] && printf '%s\n' "$STUB_PRLIST_FAIL_REPOS" | grep -qxF "$repo"; then
    exit 1
  fi
  f="$FIX/prlist/$(key "$repo").json"
  if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
  exit 0
fi

if [ "$1" = "api" ]; then
  # The real invocation may carry --paginate (or other flags) before the
  # path; find the first non-flag positional argument after "api".
  path=""
  for a in "$@"; do
    [ "$a" = "api" ] && continue
    case "$a" in
      --*) continue ;;
      *) path="$a"; break ;;
    esac
  done
  # Strip any query string before pattern-matching/extraction, mirroring
  # what a real endpoint would see as the path (both ?per_page=100 on
  # reviews/status/timeline and --paginate as a flag must not perturb
  # fixture routing).
  path_no_query="${path%%\?*}"
  case "$path_no_query" in
    repos/*/pulls/*/reviews)
      [ -n "${STUB_REVIEWS_FAIL:-}" ] && exit 1
      repo="$(printf '%s' "$path_no_query" | sed -E 's#repos/([^/]+/[^/]+)/pulls/.*#\1#')"
      pr="$(printf '%s' "$path_no_query" | sed -E 's#repos/[^/]+/[^/]+/pulls/([0-9]+)/.*#\1#')"
      f="$FIX/reviews/$(key "$repo")-$pr.json"
      if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
      exit 0
      ;;
    repos/*/commits/*/status)
      [ -n "${STUB_STATUS_FAIL:-}" ] && exit 1
      [ -n "${STUB_STATUS_MALFORMED:-}" ] && { echo 'not json'; exit 0; }
      repo="$(printf '%s' "$path_no_query" | sed -E 's#repos/([^/]+/[^/]+)/commits/.*#\1#')"
      sha="$(printf '%s' "$path_no_query" | sed -E 's#repos/[^/]+/[^/]+/commits/([^/]+)/status#\1#')"
      f="$FIX/status/$(key "$repo")-$sha.json"
      if [ -f "$f" ]; then cat "$f"; else echo '{"statuses":[]}'; fi
      exit 0
      ;;
    repos/*/issues/*/timeline)
      [ -n "${STUB_TIMELINE_FAIL:-}" ] && exit 1
      repo="$(printf '%s' "$path_no_query" | sed -E 's#repos/([^/]+/[^/]+)/issues/.*#\1#')"
      pr="$(printf '%s' "$path_no_query" | sed -E 's#repos/[^/]+/[^/]+/issues/([0-9]+)/.*#\1#')"
      f="$FIX/timeline/$(key "$repo")-$pr.json"
      if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
      exit 0
      ;;
    repos/*/commits/*)
      [ -n "${STUB_COMMIT_FAIL:-}" ] && exit 1
      repo="$(printf '%s' "$path_no_query" | sed -E 's#repos/([^/]+/[^/]+)/commits/.*#\1#')"
      sha="$(printf '%s' "$path_no_query" | sed -E 's#repos/[^/]+/[^/]+/commits/([^/]+)#\1#')"
      f="$FIX/commit/$(key "$repo")-$sha.json"
      if [ -f "$f" ]; then cat "$f"; else printf '{"commit":{"committer":{"date":"%s"}}}' "${STUB_DEFAULT_COMMIT_DATE:-2026-01-01T00:00:00Z}"; fi
      exit 0
      ;;
  esac
fi
echo "gh stub: unhandled invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUBBIN/gh"

  # --- openclaw stub (cron list only) --------------------------------------
  cat > "$STUBBIN/openclaw" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_CRON_FAIL:-}" ] && exit 1
if [ -f "${STUB_CRON_JSON:-}" ]; then cat "$STUB_CRON_JSON"; else echo '{"jobs":[]}'; fi
STUB
  chmod +x "$STUBBIN/openclaw"

  # --- muso stub (slack-notify.sh's transport) ------------------------------
  cat > "$STUBBIN/muso" <<'STUB'
#!/usr/bin/env bash
echo "slack-send" >> "$SLACK_CALLS"
# STUB_SLACK_FAIL_ONCE: fail the first send only, then succeed -- models a
# transient Slack/API outage so we can prove `paged` is not persisted on a
# send that never landed.
if [ -n "${STUB_SLACK_FAIL_ONCE:-}" ]; then
  if [ ! -f "$STUB_SLACK_FAIL_ONCE" ]; then
    : > "$STUB_SLACK_FAIL_ONCE"
    exit 1
  fi
fi
[ -n "${STUB_SLACK_FAIL_ALWAYS:-}" ] && exit 1
exit 0
STUB
  chmod +x "$STUBBIN/muso"
  export MUSO_SLACK_BOT_TOKEN_DEVOPS="fake-token-for-tests"

  # --- curl stub (githubstatus.com probe) -----------------------------------
  # Stubbed unconditionally so the suite NEVER reaches the real network: an
  # un-stubbed probe would make CI's verdict depend on GitHub's live status
  # page, which is exactly the kind of hidden external dependency this suite
  # exists to keep out. Default = "All Systems Operational" so pre-existing
  # tests see the local-cause wording.
  export CURL_CALLS="$TEST_TMPDIR/curl_calls"; : > "$CURL_CALLS"
  cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_CALLS"
[ -n "${STUB_GH_STATUS_FAIL:-}" ] && exit 1
if [ -n "${STUB_GH_STATUS_BODY:-}" ]; then printf '%s' "$STUB_GH_STATUS_BODY"; exit 0; fi
printf '%s' '{"status":{"description":"All Systems Operational"},"components":[]}'
STUB
  chmod +x "$STUBBIN/curl"

  # --- allowlist stub --------------------------------------------------------
  ALLOWLIST_STUB="$TEST_TMPDIR/allowlist.sh"
  cat > "$ALLOWLIST_STUB" <<'STUB'
#!/usr/bin/env bash
# Mirrors the real contract: enumeration is env-gated AND argument-free, so an
# argv flag can never enumerate. Any argument is the fail-closed predicate.
[ "$#" -eq 0 ] || exit 1
[ "${QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE:-}" = "1" ] || exit 2
printf '%s\n' "${STUB_ALLOWLIST_REPOS:-Muso-AI/core-backend}"
STUB
  chmod +x "$ALLOWLIST_STUB"

  # --- author-uid stub ---------------------------------------------------
  AUTHOR_STUB="$TEST_TMPDIR/author-uid.sh"
  cat > "$AUTHOR_STUB" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_AUTHOR_FAIL_RC:-}" ] && exit "$STUB_AUTHOR_FAIL_RC"
case "$1" in
  nsollazzo) echo "U0AL36NADEY" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$AUTHOR_STUB"

  # --- dispatch actuator stub -----------------------------------------------
  DISPATCH_STUB="$TEST_TMPDIR/dispatch.sh"
  cat > "$DISPATCH_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$DISPATCH_CALLS"
exit 0
STUB
  chmod +x "$DISPATCH_STUB"

  # --- status actuator stub -------------------------------------------------
  STATUS_STUB="$TEST_TMPDIR/status.sh"
  cat > "$STATUS_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s %s %s\n' "$1" "$2" "$3" >> "$STATUS_CALLS"
exit 0
STUB
  chmod +x "$STATUS_STUB"

  # --- policy fixture ---------------------------------------------------
  POLICY_FIXTURE="$TEST_TMPDIR/policy.json"
  cat > "$POLICY_FIXTURE" <<'JSON'
{
  "identity": {"bot_logins": ["muso-qa-bot", "muso-qa-bot[bot]", "adk47"], "app_repos": []},
  "merge_gate_repos": [],
  "require_human_codeowner_repos": [],
  "author_deny": []
}
JSON

  # Captured BEFORE $STUBBIN is prepended to PATH, so a per-test jq stub
  # (B5) can pass through to the real binary for every call it doesn't
  # intentionally break.
  REAL_JQ="$(command -v jq)"; export REAL_JQ

  export PATH="$STUBBIN:$PATH"
  export QA_RECONCILE_ALLOWLIST_SCRIPT="$ALLOWLIST_STUB"
  export QA_RECONCILE_AUTHOR_UID_SCRIPT="$AUTHOR_STUB"
  export QA_RECONCILE_DISPATCH_SCRIPT="$DISPATCH_STUB"
  export QA_RECONCILE_STATUS_SCRIPT="$STATUS_STUB"
  export QA_RECONCILE_POLICY="$POLICY_FIXTURE"
  export QA_RECONCILE_STATE_FILE="$TEST_TMPDIR/state.json"
  export QA_RECONCILE_LOCKFILE="$TEST_TMPDIR/lock"
  export QA_RECONCILE_NOW_EPOCH="$NOW_EPOCH"
  export QA_RECONCILE_GRACE_S=1800
  export QA_RECONCILE_COOLDOWN_S=1800
  export QA_RECONCILE_MAX_ATTEMPTS=2
  export QA_RECONCILE_GLOBAL_CAP=3
  export QA_RECONCILE_CRON_STALE_S=1800
  export QA_RECONCILE_AGE_CEILING_S=1209600
  export QA_RECONCILE_TICK_FAIL_THRESHOLD=3
  unset STUB_SLACK_FAIL_ONCE STUB_SLACK_FAIL_ALWAYS STUB_REVIEWS_FAIL STUB_STATUS_FAIL STUB_STATUS_MALFORMED STUB_TIMELINE_FAIL STUB_COMMIT_FAIL STUB_CRON_JSON STUB_CRON_FAIL STUB_ALLOWLIST_REPOS STUB_DEFAULT_COMMIT_DATE STUB_AUTHOR_FAIL_RC STUB_PRLIST_FAIL_REPOS STUB_GH_STATUS_FAIL STUB_GH_STATUS_BODY STUB_ROLLUP_FAIL STUB_ROLLUP_MALFORMED
  # Long enough that every pre-existing test keeps its single-page semantics
  # (each seeds a fresh state dir, so nothing is ever suppressed by inheritance);
  # the dedupe tests below set their own value.
  export QA_RECONCILE_READ_FAIL_ALERT_INTERVAL=21600
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Recent push (well inside the grace window's "old enough" side but inside
# age scope): NOW_EPOCH - 3600 (1h ago) — past the 30min grace, well within
# the repo epoch / 14d ceiling once the repo epoch is seeded old enough.
RECENT_ISO='2033-05-18T00:00:00Z'   # arbitrary fixed date matched to NOW_EPOCH below via override
mk_pr_list() {
  # mk_pr_list <repo> <pr> <sha> <base> <draft> <login> <updated_at> [created_at]
  # created_at defaults to updated_at when omitted (keeps every pre-A1 caller
  # working unchanged).
  local repo="$1" pr="$2" sha="$3" base="$4" draft="$5" login="$6" updated="$7" created="${8:-$7}"
  local f="$FIX/prlist/$(printf '%s' "$repo" | tr '/' '-').json"
  cat > "$f" <<JSON
[{"number": $pr, "headRefOid": "$sha", "baseRefName": "$base", "isDraft": $draft, "author": {"login": "$login"}, "updatedAt": "$updated", "createdAt": "$created", "url": "https://github.com/$repo/pull/$pr"}]
JSON
}

mk_commit() {
  # mk_commit <repo> <sha> <iso-date>
  local repo="$1" sha="$2" iso="$3"
  cat > "$FIX/commit/$(printf '%s' "$repo" | tr '/' '-')-$sha.json" <<JSON
{"commit": {"committer": {"date": "$iso"}}}
JSON
}

seed_epoch_state() {
  # Pre-seed a state file whose repo epoch is old enough that any test's
  # (much later, 2026-dated) push is in scope, avoiding first-run/pre-epoch
  # interference in tests that are about later-stage logic (verdict,
  # suppressor, caps). Deliberately NOT derived from $NOW_EPOCH/
  # $QA_RECONCILE_NOW_EPOCH: callers seed state BEFORE overriding
  # QA_RECONCILE_NOW_EPOCH to their own test-specific "now", so an epoch
  # computed from either at call time would be seeded against the wrong
  # clock. A fixed near-zero epoch is always older than any realistic test
  # "now" while still inside the 14d ceiling relative to it.
  jq -n --arg r "$1" --argjson e 1 '{"__repo_epochs__": {($r): $e}}' > "$QA_RECONCILE_STATE_FILE"
}

@test "e2e 1: expected PR with no verdict -> exactly one dispatch" {
  seed_epoch_state "Muso-AI/core-backend"
  mk_pr_list "Muso-AI/core-backend" 10 "sha0010000000000000000000000000000000010" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "sha0010000000000000000000000000000000010" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$DISPATCH_CALLS" | tr -d ' ')" -eq 1 ]
  grep -q "10 sha0010000000000000000000000000000000010 Muso-AI/core-backend U0AL36NADEY" "$DISPATCH_CALLS"
}

@test "e2e 2: a bot review on the head sha is a verdict -> no dispatch" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shaverdict00000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 11 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  cat > "$FIX/reviews/Muso-AI-core-backend-11.json" <<JSON
[{"commit_id": "$sha", "user": {"login": "muso-qa-bot"}}]
JSON
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 3: a terminal qa-review status is a verdict -> no dispatch; pending on a non-gated repo also suppresses" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shaterm000000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 12 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  cat > "$FIX/status/Muso-AI-core-backend-$sha.json" <<JSON
{"statuses": [{"context": "qa-review", "state": "failure"}]}
JSON
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 4: draft PR -> no dispatch" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shadraft0000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 13 "$sha" main true nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 5: unmapped author -> no dispatch" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shaunmap0000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 14 "$sha" main false "someone-unmapped" "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 6: non-gated base -> no dispatch" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shabase00000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 15 "$sha" "feature/x" false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 7: a live, FRESH (running/queued) cron job suppresses re-dispatch" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shacron00000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 16 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  # runningAtMs 60s ago -- well within the 1800s freshness budget.
  running_at_ms=$(( (QA_RECONCILE_NOW_EPOCH - 60) * 1000 ))
  cat > "$TEST_TMPDIR/cron.json" <<JSON
{"jobs": [{"name": "qa-autoreview-pr-Muso-AI-core-backend-16", "state": {"runningAtMs": $running_at_ms}}]}
JSON
  export STUB_CRON_JSON="$TEST_TMPDIR/cron.json"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 7a: a live cron row with nextRunAtMs in the near future still suppresses -- no dispatch" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shacronq0000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 16 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  # nextRunAtMs 5 min in the future -- never run, not past-due.
  next_run_at_ms=$(( (QA_RECONCILE_NOW_EPOCH + 300) * 1000 ))
  cat > "$TEST_TMPDIR/cron.json" <<JSON
{"jobs": [{"name": "qa-autoreview-pr-Muso-AI-core-backend-16", "state": {"nextRunAtMs": $next_run_at_ms}}]}
JSON
  export STUB_CRON_JSON="$TEST_TMPDIR/cron.json"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 7b: a past-due, never-fired nextRunAtMs (older than the freshness budget) is NOT suppressed -- dispatched (the exact bug-reintroduction scenario)" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shacronqs000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 16 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  # nextRunAtMs 1h past-due, no lastRunAtMs/runningAtMs anywhere: a gateway
  # restart before this one-shot fired, and openclaw never re-armed it. The
  # dispatch-side sweep deliberately never deletes this row (see
  # qa-dispatch-pr-review.sh), so it survives at exactly this shape forever
  # unless the suppressor is bounded by freshness.
  next_run_at_ms=$(( (QA_RECONCILE_NOW_EPOCH - 3600) * 1000 ))
  cat > "$TEST_TMPDIR/cron.json" <<JSON
{"jobs": [{"name": "qa-autoreview-pr-Muso-AI-core-backend-16", "state": {"nextRunAtMs": $next_run_at_ms}}]}
JSON
  export STUB_CRON_JSON="$TEST_TMPDIR/cron.json"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$DISPATCH_CALLS" ]
  grep -q "16 $sha Muso-AI/core-backend U0AL36NADEY" "$DISPATCH_CALLS"
}

@test "e2e 7c: a fresh runningAtMs still suppresses -- no dispatch" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shacronrf000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 16 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  running_at_ms=$(( (QA_RECONCILE_NOW_EPOCH - 300) * 1000 ))
  cat > "$TEST_TMPDIR/cron.json" <<JSON
{"jobs": [{"name": "qa-autoreview-pr-Muso-AI-core-backend-16", "state": {"runningAtMs": $running_at_ms}}]}
JSON
  export STUB_CRON_JSON="$TEST_TMPDIR/cron.json"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 7d: a stale runningAtMs (a killed run, older than the freshness budget) is NOT suppressed -- dispatched" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shacronrs000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 16 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  running_at_ms=$(( (QA_RECONCILE_NOW_EPOCH - 3600) * 1000 ))
  cat > "$TEST_TMPDIR/cron.json" <<JSON
{"jobs": [{"name": "qa-autoreview-pr-Muso-AI-core-backend-16", "state": {"runningAtMs": $running_at_ms}}]}
JSON
  export STUB_CRON_JSON="$TEST_TMPDIR/cron.json"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$DISPATCH_CALLS" ]
  grep -q "16 $sha Muso-AI/core-backend U0AL36NADEY" "$DISPATCH_CALLS"
}

@test "e2e 8c: an exhaustion page that FAILS to deliver does not persist paged=true -- the next tick retries and delivers" {
  # slack_notify_critical() is fire-and-forget by design, so page() always
  # "succeeds". Persisting paged=true off that would turn a transient Slack
  # outage into a permanently unmentioned lost review -- the exact silent-loss
  # invariant this reconciler exists to eliminate.
  sha="shapage00000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 43 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 7200 ))"
  jq -n --argjson e "$((now - 100000))" --argjson last "$((now - 5000))" '
    {"__repo_epochs__": {"Muso-AI/core-backend": $e},
     "Muso-AI/core-backend#43@shapage00000000000000000000000000000001": {"attempts": 2, "last_attempt_epoch": $last, "paged": false}}
  ' > "$QA_RECONCILE_STATE_FILE"
  export QA_RECONCILE_NOW_EPOCH="$now"

  # Tick 1: the Slack transport fails.
  export STUB_SLACK_FAIL_ONCE="$TEST_TMPDIR/slack-failed-once"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(jq -r '."Muso-AI/core-backend#43@shapage00000000000000000000000000000001".paged' "$QA_RECONCILE_STATE_FILE")" = "false" ]

  # Tick 2: transport recovers -> the page is retried and delivered, and only
  # now is paged persisted.
  : > "$SLACK_CALLS"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$SLACK_CALLS" ]
  [ "$(jq -r '."Muso-AI/core-backend#43@shapage00000000000000000000000000000001".paged' "$QA_RECONCILE_STATE_FILE")" = "true" ]
}

@test "e2e 8a: attempts==MAX but a FRESH queued cron row is in flight -> NO page, NO red status (exhaustion must not pre-empt the final attempt)" {
  # Ordering regression. Exhaustion used to be evaluated BEFORE the cooldown and
  # the freshness suppressor, so the final attempt could be declared lost while it
  # was still legitimately queued: attempt 2 dispatches, the serialized qa lane
  # holds the one-shot for ~15 min, and the next tick sees attempts == MAX and
  # paged + drove a merge-gated PR red over a review that was about to run.
  sha="shaflight000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 41 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 7200 ))"
  # Cooldown elapsed, so ONLY the fresh cron row can hold exhaustion back.
  jq -n --argjson e "$((now - 100000))" --argjson last "$((now - 5000))" '
    {"__repo_epochs__": {"Muso-AI/core-backend": $e},
     "Muso-AI/core-backend#41@shaflight000000000000000000000000000001": {"attempts": 2, "last_attempt_epoch": $last, "paged": false}}
  ' > "$QA_RECONCILE_STATE_FILE"
  export STUB_CRON_JSON="$TEST_TMPDIR/cron.json"
  jq -n --argjson n "$(( (now + 60) * 1000 ))" '
    {"hasMore": false,
     "jobs": [{"id":"j-inflight","name":"qa-autoreview-pr-Muso-AI-core-backend-41",
               "status":"pending","state":{"nextRunAtMs":$n}}]}
  ' > "$STUB_CRON_JSON"
  export QA_RECONCILE_NOW_EPOCH="$now"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
  [ ! -s "$SLACK_CALLS" ]
  [ ! -s "$STATUS_CALLS" ]
}

@test "e2e 8b: attempts==MAX with a STALE queued cron row DOES page (freshness, not presence, is what holds exhaustion back)" {
  sha="shastale0000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 42 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 7200 ))"
  jq -n --argjson e "$((now - 100000))" --argjson last "$((now - 5000))" '
    {"__repo_epochs__": {"Muso-AI/core-backend": $e},
     "Muso-AI/core-backend#42@shastale0000000000000000000000000000001": {"attempts": 2, "last_attempt_epoch": $last, "paged": false}}
  ' > "$QA_RECONCILE_STATE_FILE"
  export STUB_CRON_JSON="$TEST_TMPDIR/cron.json"
  jq -n --argjson n "$(( (now - 99999) * 1000 ))" '
    {"hasMore": false,
     "jobs": [{"id":"j-stale","name":"qa-autoreview-pr-Muso-AI-core-backend-42",
               "status":"pending","state":{"nextRunAtMs":$n}}]}
  ' > "$STUB_CRON_JSON"
  export QA_RECONCILE_NOW_EPOCH="$now"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SLACK_CALLS" | tr -d ' ')" -eq 1 ]
}

@test "e2e 8: attempts cap of 2 -> no third dispatch, pages exactly once; NOT merge-gated (policy default merge_gate_repos: []) so qa-review-status.sh is never called" {
  sha="shacap0000000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 17 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 7200 ))"
  jq -n --argjson e "$((now - 100000))" --argjson last "$((now - 5000))" '
    {"__repo_epochs__": {"Muso-AI/core-backend": $e},
     "Muso-AI/core-backend#17@shacap0000000000000000000000000000000001": {"attempts": 2, "last_attempt_epoch": $last, "paged": false}}
  ' > "$QA_RECONCILE_STATE_FILE"
  export QA_RECONCILE_NOW_EPOCH="$now"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
  [ "$(wc -l < "$SLACK_CALLS" | tr -d ' ')" -eq 1 ]
  [ ! -s "$STATUS_CALLS" ]
  # a second tick must not re-page (paged=true is now persisted)
  : > "$SLACK_CALLS"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]
  [ ! -s "$STATUS_CALLS" ]
}

@test "e2e 9: cooldown respected -> no re-dispatch within the window" {
  sha="shacool0000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 18 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 7200 ))"
  jq -n --argjson e "$((now - 100000))" --argjson last "$((now - 100))" '
    {"__repo_epochs__": {"Muso-AI/core-backend": $e},
     "Muso-AI/core-backend#18@shacool0000000000000000000000000000001": {"attempts": 1, "last_attempt_epoch": $last, "paged": false}}
  ' > "$QA_RECONCILE_STATE_FILE"
  export QA_RECONCILE_NOW_EPOCH="$now"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 10: unparseable state file refuses and pages; dispatch script never invoked" {
  echo 'not json' > "$QA_RECONCILE_STATE_FILE"
  mk_pr_list "Muso-AI/core-backend" 19 "shabadstate0000000000000000000000000001" main false nsollazzo "2026-01-01T00:00:00Z"
  run "$SCRIPT" --once
  [ "$status" -eq 1 ]
  [ ! -s "$DISPATCH_CALLS" ]
  [ -s "$SLACK_CALLS" ]
}

@test "e2e 11: head sha change starts a fresh key/attempts even though the OLD sha's key is exhausted" {
  old_sha="shaold00000000000000000000000000000001"
  new_sha="shanew00000000000000000000000000000002"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 7200 ))"
  jq -n --argjson e "$((now - 100000))" --argjson last "$((now - 5000))" '
    {"__repo_epochs__": {"Muso-AI/core-backend": $e},
     ("Muso-AI/core-backend#20@" + "shaold00000000000000000000000000000001"): {"attempts": 2, "last_attempt_epoch": $last, "paged": true}}
  ' > "$QA_RECONCILE_STATE_FILE"
  mk_pr_list "Muso-AI/core-backend" 20 "$new_sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$new_sha" "2026-01-01T00:00:00Z"
  export QA_RECONCILE_NOW_EPOCH="$now"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$DISPATCH_CALLS" | tr -d ' ')" -eq 1 ]
  grep -q "20 $new_sha" "$DISPATCH_CALLS"
}

@test "e2e 12: global per-tick cap of 3 -> a 4th eligible PR is not dispatched this tick" {
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  jq -n --argjson e "$((now - 100000))" '{"__repo_epochs__": {"Muso-AI/core-backend": $e}}' > "$QA_RECONCILE_STATE_FILE"
  f="$FIX/prlist/Muso-AI-core-backend.json"
  echo '[' > "$f"
  for i in 1 2 3 4; do
    sha="shacap4pr0000000000000000000000000000$i"
    mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
    [ "$i" -gt 1 ] && echo ',' >> "$f"
    printf '{"number": %d, "headRefOid": "%s", "baseRefName": "main", "isDraft": false, "author": {"login": "nsollazzo"}, "updatedAt": "2026-01-01T00:00:00Z", "url": "https://x/%d"}' "$((30+i))" "$sha" "$((30+i))" >> "$f"
  done
  echo ']' >> "$f"
  export QA_RECONCILE_NOW_EPOCH="$now"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$DISPATCH_CALLS" | tr -d ' ')" -eq 3 ]
}

@test "e2e 13: cron list hasMore=true does not suppress forever -- acts past 2x grace, stays suppressed before it" {
  sha="shahasmore00000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 21 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  cat > "$TEST_TMPDIR/cron.json" <<'JSON'
{"jobs": [], "hasMore": true}
JSON
  export STUB_CRON_JSON="$TEST_TMPDIR/cron.json"
  base_now="$(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s)"
  jq -n --argjson e "$((base_now - 100000))" '{"__repo_epochs__": {"Muso-AI/core-backend": $e}}' > "$QA_RECONCILE_STATE_FILE"

  # Within grace (45min > 30min single grace, but strictly < 2x grace =
  # 60min): suppressed. (qar_grace_ok is inclusive of the boundary, so this
  # must stay strictly under 3600s to exercise the "still suppressed" arm.)
  export QA_RECONCILE_NOW_EPOCH="$((base_now + 2700))"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]

  # Past 2x grace (>= 60min since trigger): acts anyway.
  : > "$DISPATCH_CALLS"
  export QA_RECONCILE_NOW_EPOCH="$((base_now + 7300))"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$DISPATCH_CALLS" ]
}

@test "e2e 14: missing state file -> dispatches nothing this tick, mints per-repo epochs, pages once" {
  sha="shamissing00000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 22 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$now"
  [ ! -f "$QA_RECONCILE_STATE_FILE" ]
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
  [ -s "$SLACK_CALLS" ]
  [ -f "$QA_RECONCILE_STATE_FILE" ]
  epoch="$(jq -r '.__repo_epochs__["Muso-AI/core-backend"]' "$QA_RECONCILE_STATE_FILE")"
  [ "$epoch" = "$now" ]
}

@test "e2e 15: a synthetic newly-onboarded repo flags ZERO pre-epoch PRs on its first tick" {
  # repo epoch minted THIS tick (= now); a PR that was pushed long before now
  # must not be flagged/dispatched -- it predates the lane by construction.
  sha="shanewrepo00000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 23 "$sha" main false nsollazzo "2020-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2020-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) ))"
  export QA_RECONCILE_NOW_EPOCH="$now"
  [ ! -f "$QA_RECONCILE_STATE_FILE" ]
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
  # Second tick, epoch now persisted -- still zero (PR predates the epoch).
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 16: excluded by head-push age, but a ready_for_review transition inside the window brings it into scope" {
  sha="shareadyfr0000000000000000000000000000001"
  # Head pushed long before the repo epoch (excluded on push alone).
  base_now="$(date -u -d "2026-06-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-06-01T00:00:00Z" +%s)"
  # createdAt is ALSO old (matches the head-push date) so createdAt alone
  # cannot rescue this PR into scope -- only the ready_for_review timeline
  # lookup below can, which is what this test exists to exercise.
  mk_pr_list "Muso-AI/core-backend" 24 "$sha" main false nsollazzo "2026-06-01T00:00:00Z" "2020-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2020-01-01T00:00:00Z"
  cat > "$FIX/timeline/Muso-AI-core-backend-24.json" <<JSON
[{"event": "ready_for_review", "created_at": "2026-06-01T00:00:00Z"}]
JSON
  jq -n --argjson e "$((base_now - 5000000))" '{"__repo_epochs__": {"Muso-AI/core-backend": $e}}' > "$QA_RECONCILE_STATE_FILE"
  export QA_RECONCILE_NOW_EPOCH="$((base_now + 3600))"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$DISPATCH_CALLS" ]
  # --paginate on the timeline call: a busy PR's events are oldest-first, so
  # the latest ready_for_review transition could otherwise sit past page 1.
  grep -qF "api --paginate repos/Muso-AI/core-backend/issues/24/timeline?per_page=100" "$GH_LOG"
}

@test "e2e 17: gh reviews-endpoint read failure -> PR is NOT dispatched (read-failure path, not treated as 'no verdict')" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shareadfail000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 25 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  export STUB_REVIEWS_FAIL=1
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
}

@test "e2e 18: --dry-run classifies and would-dispatch, but persists no state and dispatches nothing" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shadryrun00000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 26 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  before="$(cat "$QA_RECONCILE_STATE_FILE")"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD DISPATCH"* ]]
  [ ! -s "$DISPATCH_CALLS" ]
  after="$(cat "$QA_RECONCILE_STATE_FILE")"
  [ "$before" = "$after" ]
}

@test "e2e: unknown flag exits 2" {
  run "$SCRIPT" --bogus-flag
  [ "$status" -eq 2 ]
}

@test "e2e 19: a failed cron list read does not burn an attempt and does not page (bound by the 2x-grace escape, not treated as 'no suppressor')" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shacronfail000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 27 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  export STUB_CRON_FAIL=1
  base_now="$(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s)"
  # Past single grace (30min) but strictly under 2x grace (60min): the
  # BLOCKER-1 bug dispatched immediately here (empty cron_json fell through
  # both case arms). Fixed behavior: suppressed, no attempt burned, no page.
  QA_RECONCILE_NOW_EPOCH="$((base_now + 2700))"
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
  [ ! -s "$SLACK_CALLS" ]
  attempts="$(jq -r --arg k "Muso-AI/core-backend#27@$sha" '.[$k].attempts // 0' "$QA_RECONCILE_STATE_FILE")"
  [ "$attempts" -eq 0 ]

  # Past 2x grace: the same escape that already exists for hasMore=true
  # still fires (a permanently failing cron read must still eventually act).
  QA_RECONCILE_NOW_EPOCH="$((base_now + 7300))"
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$DISPATCH_CALLS" ]
}

@test "e2e 20: merge-gated repo — attempts-exhausted drives qa-review status to failure" {
  GATED_POLICY="$TEST_TMPDIR/gated-policy.json"
  cat > "$GATED_POLICY" <<'JSON'
{
  "identity": {"bot_logins": ["muso-qa-bot", "muso-qa-bot[bot]", "adk47"], "app_repos": []},
  "merge_gate_repos": ["Muso-AI/core-backend"],
  "require_human_codeowner_repos": [],
  "author_deny": []
}
JSON
  export QA_RECONCILE_POLICY="$GATED_POLICY"
  sha="shagated0000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 28 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 7200 ))"
  jq -n --argjson e "$((now - 100000))" --argjson last "$((now - 5000))" \
    --arg k "Muso-AI/core-backend#28@$sha" '
    {"__repo_epochs__": {"Muso-AI/core-backend": $e},
     ($k): {"attempts": 2, "last_attempt_epoch": $last, "paged": false}}
  ' > "$QA_RECONCILE_STATE_FILE"
  export QA_RECONCILE_NOW_EPOCH="$now"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$STATUS_CALLS" ]
  grep -qF "Muso-AI/core-backend $sha failure" "$STATUS_CALLS"
}

@test "e2e 21: a done (already ran, completed) cron row does not suppress -- dispatches" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shacrondone00000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 29 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  cat > "$TEST_TMPDIR/cron.json" <<'JSON'
{"jobs": [{"name": "qa-autoreview-pr-Muso-AI-core-backend-29", "state": {"lastRunAtMs": 1, "lastStatus": "ok"}}]}
JSON
  export STUB_CRON_JSON="$TEST_TMPDIR/cron.json"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$DISPATCH_CALLS" ]
  grep -q "29 $sha Muso-AI/core-backend U0AL36NADEY" "$DISPATCH_CALLS"
}

@test "e2e 22: malformed combined-status JSON -> read-failure path, NOT treated as 'no verdict' (no dispatch)" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shastatusmalformed0000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 30 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  export STUB_STATUS_MALFORMED=1
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
  [[ "$output" == *"READ-FAILURE"*"could not parse combined status JSON"* ]]
}

@test "e2e 23: reviews call carries --paginate; reviews and status calls carry per_page=100" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shapaginate00000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 31 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  grep -qF "api --paginate repos/Muso-AI/core-backend/pulls/31/reviews?per_page=100" "$GH_LOG"
  grep -qF "api repos/Muso-AI/core-backend/commits/$sha/status?per_page=100" "$GH_LOG"
}

@test "e2e 24: a jq failure enumerating state keys for pruning skips the prune (fail-closed) instead of wiping every attempt counter, and pages" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shaprunejqfail0000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 32 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  # A stale key for a PR that is NOT in the open-PR fixture above: on a
  # healthy tick this would be pruned away (closed/merged). If a jq failure
  # during enumeration silently produced an empty key list, qar_state_keep_only
  # would strip it anyway -- so its SURVIVAL through a jq-failure tick is the
  # proof the prune was skipped, not "accidentally" run to the same result.
  jq -n --argjson e "$((now - 100000))" '
    {"__repo_epochs__": {"Muso-AI/core-backend": $e},
     "Muso-AI/core-backend#999@shaclosedstale00000000000000000000001": {"attempts": 1, "last_attempt_epoch": 1, "paged": false}}
  ' > "$QA_RECONCILE_STATE_FILE"

  # jq stub: fail ONLY the exact prune key-enumeration query; pass every
  # other call through to the real binary (captured pre-PATH-shadow as
  # $REAL_JQ), so the rest of the tick behaves normally.
  cat > "$STUBBIN/jq" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-r" ] && [ "\$2" = 'keys[] | select(. != "__meta__" and . != "__repo_epochs__" and . != "__ready_cache__")' ]; then
  exit 1
fi
exec "$REAL_JQ" "\$@"
STUB
  chmod +x "$STUBBIN/jq"

  export QA_RECONCILE_NOW_EPOCH="$now"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$SLACK_CALLS" ]
  stale_attempts="$(jq -r '.["Muso-AI/core-backend#999@shaclosedstale00000000000000000000001"].attempts // "MISSING"' "$QA_RECONCILE_STATE_FILE")"
  [ "$stale_attempts" = "1" ]
}

@test "e2e 25: PAGE CAP bounds the exhaustion-page/red-status actuator per tick -- a second exhausted key is deferred, not paged" {
  export QA_RECONCILE_PAGE_CAP=1
  sha1="shapagecap0000000000000000000000000001"
  sha2="shapagecap0000000000000000000000000002"
  f="$FIX/prlist/Muso-AI-core-backend.json"
  cat > "$f" <<JSON
[{"number": 40, "headRefOid": "$sha1", "baseRefName": "main", "isDraft": false, "author": {"login": "nsollazzo"}, "updatedAt": "2026-01-01T00:00:00Z", "createdAt": "2026-01-01T00:00:00Z", "url": "https://x/40"},
 {"number": 41, "headRefOid": "$sha2", "baseRefName": "main", "isDraft": false, "author": {"login": "nsollazzo"}, "updatedAt": "2026-01-01T00:00:00Z", "createdAt": "2026-01-01T00:00:00Z", "url": "https://x/41"}]
JSON
  mk_commit "Muso-AI/core-backend" "$sha1" "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha2" "2026-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 7200 ))"
  jq -n --argjson e "$((now - 100000))" --argjson last "$((now - 5000))" --arg k1 "Muso-AI/core-backend#40@$sha1" --arg k2 "Muso-AI/core-backend#41@$sha2" '
    {"__repo_epochs__": {"Muso-AI/core-backend": $e},
     ($k1): {"attempts": 2, "last_attempt_epoch": $last, "paged": false},
     ($k2): {"attempts": 2, "last_attempt_epoch": $last, "paged": false}}
  ' > "$QA_RECONCILE_STATE_FILE"
  export QA_RECONCILE_NOW_EPOCH="$now"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SLACK_CALLS" | tr -d ' ')" -eq 1 ]
  paged1="$(jq -r --arg k "Muso-AI/core-backend#40@$sha1" '.[$k].paged' "$QA_RECONCILE_STATE_FILE")"
  paged2="$(jq -r --arg k "Muso-AI/core-backend#41@$sha2" '.[$k].paged' "$QA_RECONCILE_STATE_FILE")"
  # Exactly one of the two was paged this tick; the other was deferred
  # (cap bites, neither is silently dropped).
  [ "$paged1" = "true" ] || [ "$paged2" = "true" ]
  [ "$paged1" = "false" ] || [ "$paged2" = "false" ]
  [[ "$output" == *"PAGE CAP: paged 1 exhausted key(s) this tick (cap 1), and 1 more"* ]]

  # A second tick pages the deferred key too (never silently dropped).
  : > "$SLACK_CALLS"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SLACK_CALLS" | tr -d ' ')" -eq 1 ]
  paged1="$(jq -r --arg k "Muso-AI/core-backend#40@$sha1" '.[$k].paged' "$QA_RECONCILE_STATE_FILE")"
  paged2="$(jq -r --arg k "Muso-AI/core-backend#41@$sha2" '.[$k].paged' "$QA_RECONCILE_STATE_FILE")"
  [ "$paged1" = "true" ]
  [ "$paged2" = "true" ]
}

@test "e2e 26: a long-lived non-draft branch (stale last commit, recent createdAt) is NOT permanently pre-epoch-ignored" {
  # Repo epoch minted long before the PR's OLD commit date -- on committer.date
  # alone this PR would be pre-epoch forever. createdAt is recent (inside
  # scope), so trigger_time = max(old commit, recent createdAt) brings it in.
  base_now="$(date -u -d "2026-06-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-06-01T00:00:00Z" +%s)"
  sha="shastalebranch000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 33 "$sha" main false nsollazzo "2026-06-01T00:00:00Z" "2026-06-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2020-01-01T00:00:00Z"
  jq -n --argjson e "$((base_now - 5000000))" '{"__repo_epochs__": {"Muso-AI/core-backend": $e}}' > "$QA_RECONCILE_STATE_FILE"
  export QA_RECONCILE_NOW_EPOCH="$((base_now + 3600))"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$DISPATCH_CALLS" ]
}

@test "e2e 27: a commit dated 30 days in the future is discarded as untrusted; trigger_time falls back to createdAt (2h ago) and dispatches once grace passes" {
  # A future committer date is author-controlled (GIT_COMMITTER_DATE) and
  # must never gate the reconciler: the old "clamp to now" behavior re-clamped
  # every tick and never let qar_grace_ok's window elapse (it mutation-tested
  # as inert). The fix discards the future date outright and falls back to
  # createdAt, which GitHub controls. createdAt here is 2h ago -- already
  # past the 30min grace -- so this PR is in scope and dispatches on the
  # FIRST tick, unlike the old clamp-based behavior which required a second,
  # much-later tick.
  seed_epoch_state "Muso-AI/core-backend"
  sha="shafuturedated000000000000000000000001"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 7200 ))"
  future_iso="$(date -u -d "@$((now + 2592000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -j -f '%s' "$((now + 2592000))" +%Y-%m-%dT%H:%M:%SZ)"
  created_iso="$(date -u -d "@$((now - 7200))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -j -f '%s' "$((now - 7200))" +%Y-%m-%dT%H:%M:%SZ)"
  mk_pr_list "Muso-AI/core-backend" 34 "$sha" main false nsollazzo "$created_iso" "$created_iso"
  mk_commit "Muso-AI/core-backend" "$sha" "$future_iso"
  export QA_RECONCILE_NOW_EPOCH="$now"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"*"future committer date"* ]]
  [ -s "$DISPATCH_CALLS" ]
}

@test "e2e 28: qa-author-slack-uid.sh exiting >=2 (usage error / missing-executable class) is a read-failure, distinct from the normal rc1 unmapped-login skip" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shaauthorfail0000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 35 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  export STUB_AUTHOR_FAIL_RC=2
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
  [[ "$output" == *"READ-FAILURE"*"exited 2"*"not the normal 'unknown login' rc1"* ]]
}

@test "e2e 29: a single repo failing to list PRs for TICK_FAIL_THRESHOLD consecutive ticks pages on its own, even though the OTHER repo in scope succeeds every tick (not a whole-fleet outage)" {
  seed_epoch_state "Muso-AI/core-backend"
  export STUB_PRLIST_FAIL_REPOS="Muso-AI/hydra"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$now"

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]
  [[ "$output" != *"WHOLE-TICK FAILURE"* ]]

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$SLACK_CALLS" ]
  [[ "$output" == *"REPO FAILURE: Muso-AI/hydra has failed to list open PRs for 3 consecutive ticks"* ]]
}

@test "e2e 30: every per-PR read failing (commit fetch) for a repo whose listing keeps succeeding pages after N consecutive ticks -- distinct from the repo-LISTING counter, and a clean tick resets it" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shacandfail0000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 36 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  export STUB_COMMIT_FAIL=1
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$now"

  # gh pr list keeps succeeding every tick (STUB_COMMIT_FAIL only breaks the
  # commit-fetch endpoint) -- the pre-existing repo-listing counter (e2e 29)
  # must NOT fire here.
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]
  [[ "$output" == *"CANDIDATE READ FAILURE: Muso-AI/core-backend"*"consecutive count now 1"* ]]
  [[ "$output" != *"REPO FAILURE"* ]]

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]
  [[ "$output" == *"consecutive count now 2"* ]]

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$SLACK_CALLS" ]
  [[ "$output" == *"CANDIDATE READ FAILURE: Muso-AI/core-backend"*"consecutive count now 3"* ]]

  # A clean tick (commit fetch now succeeds) resets the durable counter to 0.
  unset STUB_COMMIT_FAIL
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  : > "$SLACK_CALLS"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  cand_n="$(jq -r '.__meta__.candidate_read_failures["Muso-AI/core-backend"] // 0' "$QA_RECONCILE_STATE_FILE")"
  [ "$cand_n" -eq 0 ]
}

@test "e2e 32: reviews endpoint fails every tick while commit reads keep succeeding -- pages at the per-STAGE threshold (the aggregate counter misses this class entirely, since failed<attempted every tick)" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shastagereviews0000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 41 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  export STUB_REVIEWS_FAIL=1
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$now"

  # commit reads succeed every tick (mk_commit above), only reviews fails --
  # the aggregate repo_reads_failed/repo_reads_attempted ratio is 1/2 each
  # tick (commit succeeds, reviews fails), so the pre-existing aggregate
  # watchdog (candidate_read_failures) NEVER fires here. That is the hole:
  # this test's page must come from the per-stage watchdog alone.
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]
  [[ "$output" == *"STAGE READ FAILURE: Muso-AI/core-backend/reviews"*"consecutive count now 1"* ]]
  cand_n="$(jq -r '.__meta__.candidate_read_failures["Muso-AI/core-backend"] // 0' "$QA_RECONCILE_STATE_FILE")"
  [ "$cand_n" -eq 0 ]

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]
  [[ "$output" == *"consecutive count now 2"* ]]

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$SLACK_CALLS" ]
  [[ "$output" == *"STAGE READ FAILURE: Muso-AI/core-backend/reviews"*"consecutive count now 3"* ]]
  stage_n="$(jq -r '.__meta__.stage_failures["Muso-AI/core-backend"]["reviews"] // 0' "$QA_RECONCILE_STATE_FILE")"
  [ "$stage_n" -eq 3 ]
}

@test "e2e 33: status endpoint fails every tick while others succeed -- pages at the per-STAGE threshold" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shastagestatus00000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 42 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  export STUB_STATUS_FAIL=1
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$now"

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]
  [[ "$output" == *"STAGE READ FAILURE: Muso-AI/core-backend/status"*"consecutive count now 1"* ]]

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$SLACK_CALLS" ]
  [[ "$output" == *"STAGE READ FAILURE: Muso-AI/core-backend/status"*"consecutive count now 3"* ]]
  stage_n="$(jq -r '.__meta__.stage_failures["Muso-AI/core-backend"]["status"] // 0' "$QA_RECONCILE_STATE_FILE")"
  [ "$stage_n" -eq 3 ]
}

@test "e2e 34: author-uid script returning rc 127 (missing/non-executable) every tick pages at the per-STAGE threshold" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shastageauthor0000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 43 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  export STUB_AUTHOR_FAIL_RC=127
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$now"

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]
  [[ "$output" == *"STAGE READ FAILURE: Muso-AI/core-backend/author_uid"*"consecutive count now 1"* ]]

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$SLACK_CALLS" ]
  [[ "$output" == *"STAGE READ FAILURE: Muso-AI/core-backend/author_uid"*"consecutive count now 3"* ]]
  stage_n="$(jq -r '.__meta__.stage_failures["Muso-AI/core-backend"]["author_uid"] // 0' "$QA_RECONCILE_STATE_FILE")"
  [ "$stage_n" -eq 3 ]
}

@test "e2e 35: author-uid returning rc 1 (unmapped author) every tick NEVER pages, at any tick count -- the false-positive guard" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shastageunmapped000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 44 "$sha" main false "someone-unmapped" "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$now"

  # someone-unmapped always exits rc1 (the stub's default arm) -- run well
  # past the threshold (5 > TICK_FAIL_THRESHOLD=3) and confirm not one page.
  for _ in 1 2 3 4 5; do
    run "$SCRIPT" --once
    [ "$status" -eq 0 ]
    [ ! -s "$SLACK_CALLS" ]
    [[ "$output" != *"STAGE READ FAILURE"*"author_uid"* ]]
  done
  stage_n="$(jq -r '.__meta__.stage_failures["Muso-AI/core-backend"]["author_uid"] // 0' "$QA_RECONCILE_STATE_FILE")"
  [ "$stage_n" -eq 0 ]
}

@test "e2e 36: a stage that fails for a few ticks then succeeds once resets its counter -- no page" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shastagereset00000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 45 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  export STUB_STATUS_FAIL=1
  now="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$now"

  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"consecutive count now 1"* ]]
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"consecutive count now 2"* ]]
  stage_n="$(jq -r '.__meta__.stage_failures["Muso-AI/core-backend"]["status"] // 0' "$QA_RECONCILE_STATE_FILE")"
  [ "$stage_n" -eq 2 ]

  # A clean tick (status endpoint now succeeds) resets the durable counter.
  unset STUB_STATUS_FAIL
  : > "$SLACK_CALLS"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]
  stage_n="$(jq -r '.__meta__.stage_failures["Muso-AI/core-backend"]["status"] // 0' "$QA_RECONCILE_STATE_FILE")"
  [ "$stage_n" -eq 0 ]

  # And the next tick, re-failing, starts back at 1 (not still elevated).
  export STUB_STATUS_FAIL=1
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"consecutive count now 1"* ]]
  [ ! -s "$SLACK_CALLS" ]
}

@test "e2e 31: pr-list truncated (returns exactly the --limit cap) is logged and paged, and skips pruning that repo's keys so their attempt state cannot be lost" {
  export QA_RECONCILE_PRLIST_LIMIT=3
  seed_epoch_state "Muso-AI/core-backend"
  jq -n '[range(0;3) | {number: (100+.), headRefOid: ("shatrunc" + (. | tostring)), baseRefName: "main", isDraft: false, author: {login: "someone-unmapped"}, updatedAt: "2026-01-01T00:00:00Z", createdAt: "2026-01-01T00:00:00Z", url: "https://x"}]' > "$FIX/prlist/Muso-AI-core-backend.json"
  stale_key="Muso-AI/core-backend#9999@shaclosedstale0000000000000000000001"
  jq --arg k "$stale_key" '.[$k] = {"attempts": 1, "last_attempt_epoch": 1, "paged": false}' "$QA_RECONCILE_STATE_FILE" > "$QA_RECONCILE_STATE_FILE.tmp"
  mv "$QA_RECONCILE_STATE_FILE.tmp" "$QA_RECONCILE_STATE_FILE"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"TRUNCATION: Muso-AI/core-backend"*"exactly 3"* ]]
  [ -s "$SLACK_CALLS" ]
  survived="$(jq -r --arg k "$stale_key" '.[$k].attempts // "MISSING"' "$QA_RECONCILE_STATE_FILE")"
  [ "$survived" = "1" ]
}

# ── Read-failure page dedupe + upstream attribution ────────────────────────
# Regression cover for the 2026-08-17 GitHub incident: 9 repos crossed the
# read-failure threshold at once and BOTH watchdogs re-paged every 15-min tick,
# because the page was emitted straight off the counter with no rate limit.

@test "e2e 38: a sustained read failure pages ONCE per interval, not every tick -- the detection counter keeps advancing while the page is suppressed" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shadedupe000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 51 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  export STUB_COMMIT_FAIL=1
  base="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$base"

  # Ticks 1-2: below threshold, no page.
  run "$SCRIPT" --once; [ "$status" -eq 0 ]
  run "$SCRIPT" --once; [ "$status" -eq 0 ]
  [ ! -s "$SLACK_CALLS" ]

  # Tick 3: threshold reached -> pages (candidate + stage = 2 sends).
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  first_sends="$(wc -l < "$SLACK_CALLS")"
  [ "$first_sends" -gt 0 ]

  # Tick 4, 15 minutes later and still failing: the counter MUST advance (the
  # detection record is what proves the outage is ongoing) but NO new page.
  export QA_RECONCILE_NOW_EPOCH="$(( base + 900 ))"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"consecutive count now 4"* ]]
  [[ "$output" == *"page suppressed for Muso-AI/core-backend"* ]]
  [ "$(wc -l < "$SLACK_CALLS")" -eq "$first_sends" ]

  # Still suppressed just before the interval elapses.
  export QA_RECONCILE_NOW_EPOCH="$(( base + 21599 ))"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SLACK_CALLS")" -eq "$first_sends" ]

  # Once the 6h interval has elapsed the page repeats -- a still-broken repo
  # must not go quiet forever.
  export QA_RECONCILE_NOW_EPOCH="$(( base + 21600 ))"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SLACK_CALLS")" -gt "$first_sends" ]
}

@test "e2e 39: recovery CLEARS the suppression window -- a repo that breaks, recovers, then breaks again inside the interval pages again immediately" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="sharecover00000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 52 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  export STUB_COMMIT_FAIL=1
  base="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$base"

  run "$SCRIPT" --once; run "$SCRIPT" --once; run "$SCRIPT" --once
  [ -s "$SLACK_CALLS" ]

  # Recover: the stamp must be cleared alongside the counter.
  unset STUB_COMMIT_FAIL
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  export QA_RECONCILE_NOW_EPOCH="$(( base + 900 ))"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(jq -r '.__meta__.read_fail_last_alert // {} | length' "$QA_RECONCILE_STATE_FILE")" -eq 0 ]

  # Break again well inside the 6h window -- this is a NEW incident and must
  # page on its own threshold run, not inherit the previous one's silence.
  export STUB_COMMIT_FAIL=1
  : > "$SLACK_CALLS"
  export QA_RECONCILE_NOW_EPOCH="$(( base + 1800 ))"; run "$SCRIPT" --once
  export QA_RECONCILE_NOW_EPOCH="$(( base + 2700 ))"; run "$SCRIPT" --once
  [ ! -s "$SLACK_CALLS" ]
  export QA_RECONCILE_NOW_EPOCH="$(( base + 3600 ))"; run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$SLACK_CALLS" ]
}

@test "e2e 40: read-failure page names an ACTIVE GitHub incident instead of blaming our token" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shaoutage000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 53 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  export STUB_COMMIT_FAIL=1
  export STUB_GH_STATUS_BODY='{"status":{"description":"Partial System Outage"},"components":[{"name":"Pull Requests","status":"major_outage"},{"name":"API Requests","status":"degraded_performance"}]}'
  base="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$base"

  run "$SCRIPT" --once; run "$SCRIPT" --once
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTIVE INCIDENT"* ]]
  [[ "$output" == *"Partial System Outage"* ]]
  [[ "$output" == *"Pull Requests=major_outage"* ]]
  # The old text asserted a local cause; it must no longer do so under an outage.
  [[ "$output" != *"most likely LOCAL"* ]]
}

@test "e2e 41: an operational GitHub status keeps the LOCAL-cause hypothesis, and an unreadable status page is UNRESOLVED -- never silently 'healthy'" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shastatus00000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 54 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  export STUB_COMMIT_FAIL=1
  base="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$base"

  run "$SCRIPT" --once; run "$SCRIPT" --once
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"most likely LOCAL"* ]]
  [[ "$output" == *"permissions/token-scope/rate-limit"* ]]

  # Probe fails -> the page must say so, and must NOT claim either cause.
  export STUB_GH_STATUS_FAIL=1
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNRESOLVED"* ]]
  [[ "$output" != *"most likely LOCAL"* ]]
  [[ "$output" != *"ACTIVE INCIDENT"* ]]
}

@test "e2e 42: the githubstatus probe runs at most ONCE per tick no matter how many repos page, and never at all when nothing pages" {
  export STUB_ALLOWLIST_REPOS="$(printf 'Muso-AI/core-backend\nMuso-AI/feed-service')"
  seed_epoch_state "Muso-AI/core-backend"
  # seed_epoch_state writes a single-repo state; add the second repo's epoch.
  jq '.__repo_epochs__["Muso-AI/feed-service"] = 1' "$QA_RECONCILE_STATE_FILE" > "$TEST_TMPDIR/s.json"
  mv "$TEST_TMPDIR/s.json" "$QA_RECONCILE_STATE_FILE"
  mk_pr_list "Muso-AI/core-backend" 55 "shaprobe0000000000000000000000000000001" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_pr_list "Muso-AI/feed-service" 56 "shaprobe0000000000000000000000000000002" main false nsollazzo "2026-01-01T00:00:00Z"
  export STUB_COMMIT_FAIL=1
  base="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$base"

  # Ticks below the threshold page nothing, so the probe must not fire at all.
  run "$SCRIPT" --once; [ "$status" -eq 0 ]
  [ ! -s "$CURL_CALLS" ]

  run "$SCRIPT" --once; [ "$status" -eq 0 ]
  : > "$CURL_CALLS"

  # Threshold tick: 2 repos x 2 watchdogs = 4 pages, but ONE probe.
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CURL_CALLS")" -eq 1 ]
}

@test "e2e 43: a read-failure page whose Slack send FAILS does not persist the suppression stamp -- the next tick retries and delivers" {
  # Mirrors e2e 8c for the exhaustion page. page() is fire-and-forget by
  # design, so stamping off it would let ONE transient Slack error buy 6h of
  # silence on a repo whose reads are broken -- the exact silent-loss
  # invariant this reconciler exists to eliminate, reintroduced inside the
  # dedupe meant to protect it.
  seed_epoch_state "Muso-AI/core-backend"
  sha="shaslackfail000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 57 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  export STUB_COMMIT_FAIL=1
  base="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$base"

  run "$SCRIPT" --once; run "$SCRIPT" --once
  [ ! -s "$SLACK_CALLS" ]

  # Threshold tick, but Slack is down for every send this tick. FAIL_ALWAYS,
  # not FAIL_ONCE: a threshold tick emits TWO pages (candidate + stage), so
  # failing only the first would still let the second stamp and mask the bug.
  export STUB_SLACK_FAIL_ALWAYS=1
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  # Nothing may be stamped for pages that never landed.
  [ "$(jq -r '.__meta__.read_fail_last_alert // {} | length' "$QA_RECONCILE_STATE_FILE")" -eq 0 ]

  # Next tick, 15 min later: still failing, still inside the 6h window -- but
  # since nothing was ever delivered it must page again, not stay silent.
  unset STUB_SLACK_FAIL_ALWAYS
  : > "$SLACK_CALLS"
  export QA_RECONCILE_NOW_EPOCH="$(( base + 900 ))"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$SLACK_CALLS" ]
  # Delivered this time -> now the stamp persists.
  [ "$(jq -r '.__meta__.read_fail_last_alert // {} | length' "$QA_RECONCILE_STATE_FILE")" -gt 0 ]
}

@test "e2e 44: a FUTURE-dated suppression stamp does not silence a live read failure" {
  # A backward host-clock step (or corrupted state) writes a stamp ahead of
  # now. Subtracting gives a negative age, which naively reads as "inside the
  # window" and would suppress until that future time + 6h.
  seed_epoch_state "Muso-AI/core-backend"
  sha="shafuture00000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 58 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  export STUB_COMMIT_FAIL=1
  base="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"

  # Seed both stamps far in the future, alongside the repo epoch.
  jq --argjson f "$(( base + 999999 ))" '
    .__meta__.read_fail_last_alert = {"Muso-AI/core-backend": {"__candidate__": $f, "commit": $f}}
  ' "$QA_RECONCILE_STATE_FILE" > "$TEST_TMPDIR/seed.json"
  mv "$TEST_TMPDIR/seed.json" "$QA_RECONCILE_STATE_FILE"

  export QA_RECONCILE_NOW_EPOCH="$base"
  run "$SCRIPT" --once; run "$SCRIPT" --once
  : > "$SLACK_CALLS"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ -s "$SLACK_CALLS" ]
}

@test "e2e 45: a valid incident description with MALFORMED components still pages -- the decorative parse can never abort the tick" {
  # Regression for the set -e abort: `"components":[5]` makes
  # `select(.status != "operational")` raise "Cannot index number" and jq exit
  # 5. Unguarded, that killed the reconciler mid-loop under `set -euo
  # pipefail` -- before page_confirmed AND before the single end-of-tick state
  # write -- so the repo lost its page and its counter advance on every retry.
  seed_epoch_state "Muso-AI/core-backend"
  sha="shabadcomp0000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 59 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  export STUB_COMMIT_FAIL=1
  export STUB_GH_STATUS_BODY='{"status":{"description":"Partial System Outage"},"components":[5]}'
  base="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$base"

  run "$SCRIPT" --once; run "$SCRIPT" --once
  : > "$SLACK_CALLS"
  run "$SCRIPT" --once
  # The tick must COMPLETE (not abort mid-loop) ...
  [ "$status" -eq 0 ]
  [[ "$output" == *"tick complete"* ]]
  # ... the page must still go out ...
  [ -s "$SLACK_CALLS" ]
  # ... the counter advance must be persisted by the end-of-tick write ...
  [ "$(jq -r '.__meta__.stage_failures["Muso-AI/core-backend"].commit // 0' "$QA_RECONCILE_STATE_FILE")" -eq 3 ]
  # ... and the measured description survives while only the detail is dropped.
  # Step past the dedupe window first: the tick above just stamped, so a
  # same-instant rehearsal would be (correctly) suppressed and never probe.
  export QA_RECONCILE_NOW_EPOCH="$(( base + 21600 ))"
  run "$SCRIPT" --dry-run
  [[ "$output" == *"ACTIVE INCIDENT"* ]]
  [[ "$output" == *"Partial System Outage"* ]]
  # Junk entries are skipped by construction, so the note carries the measured
  # description with NO component breakdown -- and must not falsely claim the
  # collection was unparseable when it was simply empty of usable entries.
  [[ "$output" != *"component detail unavailable"* ]]
  [[ "$output" != *"=null"* ]]
}

@test "e2e 46: a components array MIXING valid objects and junk still reports the valid ones" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="shamixcomp0000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 60 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  export STUB_COMMIT_FAIL=1
  export STUB_GH_STATUS_BODY='{"status":{"description":"Partial System Outage"},"components":[5,{"name":"Pull Requests","status":"major_outage"},"junk"]}'
  base="$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))"
  export QA_RECONCILE_NOW_EPOCH="$base"

  run "$SCRIPT" --once; run "$SCRIPT" --once
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTIVE INCIDENT"* ]]
  [[ "$output" == *"Pull Requests=major_outage"* ]]
  [[ "$output" != *"component detail unavailable"* ]]
}

@test "e2e 47: a terminal rollup status on the head supplies the verdict with ZERO per-PR reads" {
  # The read-amplification cut. `statusCheckRollup` arrives with the PR list
  # (GraphQL budget); before this, every tick re-read commit+timeline+reviews+
  # status for EVERY open PR on EVERY repo to re-derive a verdict it had
  # already recorded, on the REST core budget the whole lane shares — the
  # 352 CANDIDATE/STAGE READ FAILURE events/day measured 2026-09-17.
  # Nothing else is seeded here on purpose: if the short-circuit did not fire,
  # the commit read would fall through to the stub's default and this PR would
  # be read at least once.
  seed_epoch_state "Muso-AI/core-backend"
  sha="sharollup000000000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 47 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  jq --arg s "$sha" '[.[] | .statusCheckRollup = [{"context":"qa-review","state":"success","description":"GO"}] | .headRefOid = $s]' \
    "$FIX/prlist/Muso-AI-core-backend.json" > "$FIX/prlist/tmp.json"
  mv "$FIX/prlist/tmp.json" "$FIX/prlist/Muso-AI-core-backend.json"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [ ! -s "$DISPATCH_CALLS" ]
  # No per-PR REST read was issued for this head at all.
  run grep -c "repos/Muso-AI/core-backend/commits/$sha" "$GH_LOG"
  [ "$output" = "0" ]
  [[ "$(cat "$GH_LOG")" != *"/pulls/47/reviews"* ]]
  [[ "$(cat "$GH_LOG")" != *"/issues/47/timeline"* ]]
}

@test "e2e 48: a PR with no qa-review context in its rollup still takes the read path" {
  # The other half of the contract: the cut must not swallow the PRs the
  # reconciler exists to recover. Same shape as e2e 1, but with a rollup that
  # carries only an unrelated context.
  seed_epoch_state "Muso-AI/core-backend"
  sha="sharollupmiss00000000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 48 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  jq '[.[] | .statusCheckRollup = [{"context":"pr-validate","state":"success"}] | .headRefOid = "'"$sha"'"]' \
    "$FIX/prlist/Muso-AI-core-backend.json" > "$FIX/prlist/tmp.json"
  mv "$FIX/prlist/tmp.json" "$FIX/prlist/Muso-AI-core-backend.json"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  run grep -c "repos/Muso-AI/core-backend/commits/$sha" "$GH_LOG"
  [ "$output" -ge 1 ]
}

@test "e2e 49: rollup call fails -- listing still succeeds, ROLLUP-DEGRADED logged, per-PR reads proceed" {
  # The 2026-09-18 split's core contract: an H-DevOps-shaped rollup 504 must
  # never be confused with a LISTING failure. Listing itself is untouched
  # (fixture served normally), only the separate rollup call is broken.
  # Scoped to the single-repo case (allowlist = Muso-AI/hydra, which
  # qar_expected_repos always includes and dedupes) so the tick's
  # rollup_degraded count is exact, since STUB_ROLLUP_FAIL is a global
  # knob (fails every repo's rollup call, mirroring STUB_STATUS_FAIL /
  # STUB_REVIEWS_FAIL's existing global-toggle convention).
  export STUB_ALLOWLIST_REPOS="Muso-AI/hydra"
  seed_epoch_state "Muso-AI/hydra"
  sha="sharollupfail000000000000000000000001"
  mk_pr_list "Muso-AI/hydra" 49 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/hydra" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  export STUB_ROLLUP_FAIL=1
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [[ "$output" != *"READ-FAILURE: could not list open PRs"* ]]
  [[ "$output" == *"ROLLUP-DEGRADED: statusCheckRollup unavailable for Muso-AI/hydra this tick"* ]]
  [[ "$output" == *"tick complete:"*"rollup_degraded=1"* ]]
  # Listing succeeded -> the repo-listing failure counter stays 0 (unset).
  run jq -r '.__meta__.repo_failures["Muso-AI/hydra"] // 0' "$QA_RECONCILE_STATE_FILE"
  [ "$output" = "0" ]
  # The short-circuit is disabled this tick -> the per-PR commit read fired.
  run grep -c "repos/Muso-AI/hydra/commits/$sha" "$GH_LOG"
  [ "$output" -ge 1 ]
  [ "$(wc -l < "$DISPATCH_CALLS" | tr -d ' ')" -eq 1 ]
}

@test "e2e 50: rollup call returns malformed JSON ({}) -- same degrade-not-fail handling as a hard failure" {
  export STUB_ALLOWLIST_REPOS="Muso-AI/hydra"
  seed_epoch_state "Muso-AI/hydra"
  sha="sharollupmalform0000000000000000000001"
  mk_pr_list "Muso-AI/hydra" 50 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/hydra" "$sha" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  export STUB_ROLLUP_MALFORMED=1
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [[ "$output" != *"READ-FAILURE: could not list open PRs"* ]]
  [[ "$output" == *"ROLLUP-DEGRADED: statusCheckRollup unavailable for Muso-AI/hydra this tick"* ]]
  [[ "$output" == *"tick complete:"*"rollup_degraded=1"* ]]
  run jq -r '.__meta__.repo_failures["Muso-AI/hydra"] // 0' "$QA_RECONCILE_STATE_FILE"
  [ "$output" = "0" ]
  run grep -c "repos/Muso-AI/hydra/commits/$sha" "$GH_LOG"
  [ "$output" -ge 1 ]
  [ "$(wc -l < "$DISPATCH_CALLS" | tr -d ' ')" -eq 1 ]
}

@test "e2e 51: rollup enrichment merges by PR number -- a terminal status on one PR skips only that PR" {
  # Two PRs in the same repo, distinct numbers: only #51's head carries a
  # terminal qa-review context in the rollup fixture; #52 carries none. If
  # the merge-by-number wiring were broken (e.g. rollups applied
  # positionally, or to every row), either PR could wrongly gain or lose the
  # short-circuit.
  seed_epoch_state "Muso-AI/core-backend"
  sha_a="sharollupmergea00000000000000000000001"
  sha_b="sharollupmergeb00000000000000000000001"
  f="$FIX/prlist/Muso-AI-core-backend.json"
  cat > "$f" <<JSON
[
  {"number": 51, "headRefOid": "$sha_a", "baseRefName": "main", "isDraft": false, "author": {"login": "nsollazzo"}, "updatedAt": "2026-01-01T00:00:00Z", "createdAt": "2026-01-01T00:00:00Z", "url": "https://github.com/Muso-AI/core-backend/pull/51", "statusCheckRollup": [{"context":"qa-review","state":"success"}]},
  {"number": 52, "headRefOid": "$sha_b", "baseRefName": "main", "isDraft": false, "author": {"login": "nsollazzo"}, "updatedAt": "2026-01-01T00:00:00Z", "createdAt": "2026-01-01T00:00:00Z", "url": "https://github.com/Muso-AI/core-backend/pull/52"}
]
JSON
  # The default rollup stub derives {number, statusCheckRollup} straight from
  # this same fixture file, so only #51 carries a terminal rollup; #52's
  # array default (missing key) is [].
  mk_commit "Muso-AI/core-backend" "$sha_b" "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  # #51 terminal-skipped: no per-PR read for sha_a.
  run grep -c "repos/Muso-AI/core-backend/commits/$sha_a" "$GH_LOG"
  [ "$output" = "0" ]
  # #52 has no rollup match: falls through to the read path.
  run grep -c "repos/Muso-AI/core-backend/commits/$sha_b" "$GH_LOG"
  [ "$output" -ge 1 ]
  [ "$(wc -l < "$DISPATCH_CALLS" | tr -d ' ')" -eq 1 ]
  grep -q "^52 $sha_b Muso-AI/core-backend U0AL36NADEY\$" "$DISPATCH_CALLS"
}

@test "e2e 52: the rollup enrichment call is scoped to --search updated:>=<AGE_CEILING_S date>" {
  seed_epoch_state "Muso-AI/core-backend"
  sha="sharolluspsearch000000000000000000001"
  mk_pr_list "Muso-AI/core-backend" 53 "$sha" main false nsollazzo "2026-01-01T00:00:00Z"
  mk_commit "Muso-AI/core-backend" "$sha" "2026-01-01T00:00:00Z"
  base_epoch=$(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s)
  QA_RECONCILE_NOW_EPOCH=$((base_epoch + 3600))
  export QA_RECONCILE_NOW_EPOCH
  export QA_RECONCILE_AGE_CEILING_S=864000  # fixed 10d ceiling for a fixed expected date
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  expected_date="$(date -u -d "@$((QA_RECONCILE_NOW_EPOCH - 864000))" +%Y-%m-%d 2>/dev/null || date -u -r "$((QA_RECONCILE_NOW_EPOCH - 864000))" +%Y-%m-%d)"
  run grep -F "Muso-AI/core-backend" "$ROLLUP_SEARCH_CALLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated:>=$expected_date"* ]]
}

@test "e2e 53: listing (non-rollup) call fails -- READ-FAILURE / repo-failure behaviour unchanged (see e2e 29 for the consecutive-tick page)" {
  # Confirms the split did not touch the authoritative-listing failure path:
  # this is the same shape e2e 29 already exercises across ticks (this test
  # pins the single-tick log line + counter).
  seed_epoch_state "Muso-AI/core-backend"
  mk_pr_list "Muso-AI/core-backend" 54 "shalisting0000000000000000000000000001" main false nsollazzo "2026-01-01T00:00:00Z"
  QA_RECONCILE_NOW_EPOCH=$(( $(date -u -d "2026-01-01T00:00:00Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "2026-01-01T00:00:00Z" +%s) + 3600 ))
  export QA_RECONCILE_NOW_EPOCH
  export STUB_PRLIST_FAIL_REPOS="Muso-AI/core-backend"
  run "$SCRIPT" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"READ-FAILURE: could not list open PRs for Muso-AI/core-backend"* ]]
  run jq -r '.__meta__.repo_failures["Muso-AI/core-backend"] // 0' "$QA_RECONCILE_STATE_FILE"
  [ "$output" = "1" ]
  [ ! -s "$DISPATCH_CALLS" ]
}
