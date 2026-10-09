#!/usr/bin/env bats
# Tests for the two GitHub-API hazards fixed in MUS-1336 (child of MUS-1333):
#
#  (a) `gh run list` stderr used to be thrown away at both detector call
#      sites, so a real failure (rate limit vs auth vs network) could never
#      be told apart in the log, and a single transient blip paged
#      immediately. gh_run_list_retry() now captures stderr to a file (never
#      merged into stdout -- gh's routine notices on stderr would otherwise
#      corrupt a good listing) and retries up to 3 attempts with backoff.
#
#  (b) GitHub intermittently serves a STALE workflow-runs listing: a
#      complete-looking page of OLDER runs that the truncation-based reach
#      guard cannot see, because it isn't truncated -- it's just wrong. Both
#      detectors now reject a listing whose newest run is older than their
#      own last_run_id checkpoint, treating the tick as "nothing new"
#      instead of reporting a bogus release or paging over a replica lag.
#
# This suite is a sibling of release-watch.bats and reuses the same
# stub-and-fixture approach (PATH-shadowed gh/curl/muso/openclaw, a bare git
# repo standing in for origin), extended with a fail-N-then-succeed counter
# on `gh run list` so a transient failure can be modeled deterministically.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT=""

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"

  export HYDRA_RELEASE_STATE_DIR="$TEST_TMPDIR/state"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR"

  export RELEASE_HIGHLIGHTS_TIMEOUT=5
  export RELEASES_SLACK_CHANNEL="C0TESTREL"
  export MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-test-token"
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/main.env"; : > "$MUSO_SLACK_ENV_FILE"

  # Retries must not sleep for real -- a test asserting 3 attempts happened
  # cares about the COUNT, not the wall-clock backoff.
  export RELEASE_GH_RETRY_DELAYS="0 0"

  export STUB_GH_ARGV="$TEST_TMPDIR/gh-argv";           : > "$STUB_GH_ARGV"
  export STUB_CURL_ARGV="$TEST_TMPDIR/curl-argv";       : > "$STUB_CURL_ARGV"
  export STUB_OPENCLAW_CALLS="$TEST_TMPDIR/openclaw-calls"; : > "$STUB_OPENCLAW_CALLS"
  export STUB_MUSO_ARGV="$TEST_TMPDIR/muso-argv";       : > "$STUB_MUSO_ARGV"
  export STUB_RELEASE_CREATE="$TEST_TMPDIR/release-create"; : > "$STUB_RELEASE_CREATE"

  export STUB_RUNS_JSON="$TEST_TMPDIR/runs.json"; echo '[]' > "$STUB_RUNS_JSON"
  export STUB_ROLLED_OUT=""
  export STUB_REPO_NAME=""
  export STUB_HOUR=""
  export STUB_GH_FAIL=""            # permanent gh failure, every call
  export STUB_GH_RUN_FAIL_COUNT=""  # `gh run list` fails this many times, then succeeds
  export STUB_GH_RUN_FAIL_MSG=""    # stderr text emitted on each induced failure
  export STUB_GH_RUN_FAIL_BIGSTDERR="" # if set, emit this many bytes of stderr instead of STUB_GH_RUN_FAIL_MSG
  export OPENROUTER_API_KEY="test-key"

  _build_script_tree
  _make_origin
  _write_gh_stub
  _write_curl_stub
  _write_openclaw_stub
  _write_muso_stub
  PATH="$STUBBIN:$PATH"; export PATH
}

teardown() { rm -rf "$TEST_TMPDIR"; }

_build_script_tree() {
  mkdir -p "$TEST_TMPDIR/scripts/lib"
  cp "$HYDRA_REPO/scripts/release-watch.sh" "$HYDRA_REPO/scripts/release.sh" \
     "$TEST_TMPDIR/scripts/"
  cp "$HYDRA_REPO/scripts/lib/release-announce.sh" \
     "$HYDRA_REPO/scripts/lib/release_blockkit.py" \
     "$HYDRA_REPO/scripts/lib/slack-notify.sh" "$TEST_TMPDIR/scripts/lib/"
  # auth ships DISABLED upstream; flip it on so it can drive the status
  # detector in this fixture, same as release-watch.bats.
  sed 's#^auth|Muso-AI/auth|0|#auth|Muso-AI/auth|1|#' \
    "$HYDRA_REPO/scripts/lib/release-repos.sh" > "$TEST_TMPDIR/scripts/lib/release-repos.sh"
  grep -q '^auth|Muso-AI/auth|1|' "$TEST_TMPDIR/scripts/lib/release-repos.sh" \
    || { echo "FIXTURE: could not enable the auth row" >&2; return 1; }
  SCRIPT="$TEST_TMPDIR/scripts/release-watch.sh"
}

# A bare repo standing in for origin, with one tagged baseline commit and
# two more real commits to be discovered as candidate releases.
_make_origin() {
  export ORIGIN="$TEST_TMPDIR/origin.git"
  git init --quiet --bare "$ORIGIN"
  local w="$TEST_TMPDIR/seed"
  git init --quiet -b main "$w"
  git -C "$w" config user.email t@example.com
  git -C "$w" config user.name  tester
  echo one > "$w/a"; git -C "$w" add -A
  git -C "$w" commit --quiet -m "feat(core): the first thing (#1)"
  git -C "$w" tag -a v2026.8.26 -m v2026.8.26
  export BASE_SHA="$(git -C "$w" rev-parse HEAD)"
  echo two > "$w/b"; git -C "$w" add -A
  git -C "$w" commit --quiet -m "fix(feed): stop the roster spinning forever (#2)"
  export MID_SHA="$(git -C "$w" rev-parse HEAD)"
  echo three > "$w/c"; git -C "$w" add -A
  git -C "$w" commit --quiet -m "feat(credits): show credits right after a claim (#3)"
  export SHIPPED_SHA="$(git -C "$w" rev-parse HEAD)"
  git -C "$w" remote add origin "$ORIGIN"
  git -C "$w" push --quiet origin main --tags
}

_write_gh_stub() {
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"
if [ -n "$STUB_GH_FAIL" ] && { [ "$1" = "api" ] || [ "$1" = "run" ]; }; then
  echo "gh: could not reach github.com" >&2; exit 1
fi
case "$1" in
  api)
    filter=""; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && filter="$a"; prev="$a"; done
    sha="$(printf '%s' "$2" | sed -n 's#.*/commits/\([0-9a-f]*\)/status#\1#p')"
    if [ -n "$sha" ]; then
      if printf '%s' "$STUB_ROLLED_OUT" | tr ' ' '\n' | grep -qx "$sha"; then
        body='{"state":"success","total_count":1,"statuses":[{"state":"success","context":"H-DevOps / deploy","description":"Rollout to muso-prod (success)"}]}'
      else
        body='{"state":"pending","total_count":0,"statuses":[]}'
      fi
    else
      body='[]'
    fi
    if [ -n "$filter" ]; then printf '%s' "$body" | jq -r "$filter"; else printf '%s\n' "$body"; fi
    exit 0 ;;
  run)
    if [ "$2" = "list" ]; then
      # Fail the first $STUB_GH_RUN_FAIL_COUNT invocations of `run list`,
      # then succeed. A per-process counter file is required: each `gh`
      # invocation from the script is a fresh process, so state cannot
      # live in a shell variable.
      if [ -n "${STUB_GH_RUN_FAIL_COUNT:-}" ] && [ "$STUB_GH_RUN_FAIL_COUNT" -gt 0 ]; then
        count_file="$TEST_TMPDIR/gh-run-fail-count"
        [ -f "$count_file" ] || echo 0 > "$count_file"
        n="$(cat "$count_file")"
        if [ "$n" -lt "$STUB_GH_RUN_FAIL_COUNT" ]; then
          echo $((n + 1)) > "$count_file"
          if [ -n "${STUB_GH_RUN_FAIL_BIGSTDERR:-}" ]; then
            head -c "$STUB_GH_RUN_FAIL_BIGSTDERR" /dev/zero | tr '\0' 'x' >&2
            echo >&2
          else
            echo "${STUB_GH_RUN_FAIL_MSG:-gh: synthetic transient failure}" >&2
          fi
          exit 1
        fi
      fi
      # Real `gh run list` returns the NEWEST runs and truncates at --limit.
      lim=""; prev=""
      for a in "$@"; do [ "$prev" = "--limit" ] && lim="$a"; prev="$a"; done
      if [ -n "$lim" ]; then
        jq -c "sort_by(.databaseId) | reverse | .[0:$lim]" "$STUB_RUNS_JSON"
      else
        cat "$STUB_RUNS_JSON"
      fi
      exit 0
    fi ;;
  repo)
    case "$2" in
      clone) git clone --quiet "$ORIGIN" "$4"; exit $? ;;
      view)  echo "${STUB_REPO_NAME:-Muso-AI/auth}"; exit 0 ;;
    esac ;;
  release)
    if [ "$2" = "create" ]; then printf '%s\n' "$*" >> "$STUB_RELEASE_CREATE"; exit 0; fi
    if [ "$2" = "view" ]; then
      grep -q -- "$3" "$STUB_RELEASE_CREATE" 2>/dev/null && exit 0
      exit 1
    fi ;;
  auth) exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUBBIN/gh"
}

_write_curl_stub() {
  cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CURL_ARGV"
printf '{"choices":[{"message":{"content":""}}]}'
exit 0
STUB
  chmod +x "$STUBBIN/curl"
}

_write_openclaw_stub() {
  cat > "$STUBBIN/openclaw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_OPENCLAW_CALLS"
exit 0
STUB
  chmod +x "$STUBBIN/openclaw"
}

_write_muso_stub() {
  cat > "$STUBBIN/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_MUSO_ARGV"
prev=""
for a in "$@"; do
  if [ "$prev" = "--blocks-file" ]; then cp "$a" "$TEST_TMPDIR/posted.json"; fi
  prev="$a"
done
exit 0
STUB
  chmod +x "$STUBBIN/muso"
}

_today_tag_glob() { printf 'v%s*' "$(date -u +%Y.%-m.%-d)"; }

# _set_runs <sha> <iso-date> [run-id] -- a single successful prod dispatch,
# and mark that sha as confirmed rolled out.
_set_runs() {
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": ${3:-1001}, "headSha": "$1", "conclusion": "success", "createdAt": "$2", "status": "completed" } ]
JSON
  export STUB_ROLLED_OUT="$1"
}

# _seed_state <sha> <run_at> <version> <run_id> -- the last announced release.
_seed_state() {
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=%s\nannounced_at=seed\nlast_run_at=%s\nlast_run_id=%s\n' \
    "$1" "$1" "${3:-v2026.8.26}" "${2:-2026-08-27T11:00:00Z}" "${4:-1000}" \
    > "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

_run_list_call_count() { grep -c '^run list' "$STUB_GH_ARGV" || true; }

# ─────────────────────────────────────────────────────────────────
# (a) capture stderr + retry — status detector (auth)
# ─────────────────────────────────────────────────────────────────

@test "status detector: a persistent gh failure retries 3 times and the final warn names the real error" {
  export STUB_GH_RUN_FAIL_COUNT=99
  export STUB_GH_RUN_FAIL_MSG="synthetic-rate-limit-9f3a1c"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  # Same LINE, not just somewhere in $output -- a retry log line can contain
  # "attempt N/3" and a separate line the unique string, which would let this
  # pass even if the FINAL warn never got the real error text.
  printf '%s\n' "$output" | grep -qE "gh run list failed after 3 attempts:.*synthetic-rate-limit-9f3a1c"
  [ "$(_run_list_call_count)" -eq 3 ]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

@test "status detector: a huge gh stderr payload does not abort the retry loop before it completes" {
  # Coverage for the GitHub Muso QA Bot NO-GO on hydra#1031 @7212dcf7. NOTE:
  # this call site can't actually reproduce the SIGPIPE the bot described --
  # gh_run_list_retry only ever runs inside a nested command substitution
  # (next_release_by_status's own `paired="$(...)"`, wrapping this
  # function's `runs="$(gh_run_list_retry ...)"`), and hand-testing that
  # exact 3-deep nesting shape with up to a 100MB payload on both bash 3.2
  # and 5.3 never propagates the inner pipeline's 141 past the outer
  # substitutions. The genuinely reachable half of the bug is the
  # `--bootstrap` path below, which runs at the script's top level with no
  # enclosing `$(...)` -- see that test for the real repro. This test stays
  # as a behavior-contract regression: 3 attempts and the failure message
  # must survive a large payload even if this path is currently immune.
  export STUB_GH_RUN_FAIL_COUNT=99
  export STUB_GH_RUN_FAIL_BIGSTDERR=65536

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh run list failed after 3 attempts"* ]]
  [ "$(_run_list_call_count)" -eq 3 ]
}

@test "status detector: a transient failure (fails twice, succeeds 3rd) is a normal, successful tick" {
  export STUB_GH_RUN_FAIL_COUNT=2
  export STUB_GH_RUN_FAIL_MSG="synthetic-transient"
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARN"* ]]
  [ "$(_run_list_call_count)" -eq 3 ]
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | head -1)"
  [ -n "$tag" ]
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$MID_SHA" ]
}

# ─────────────────────────────────────────────────────────────────
# (a) capture stderr + retry — hydra detector
# ─────────────────────────────────────────────────────────────────

@test "hydra detector: a persistent gh failure retries 3 times and the final warn names the real error" {
  export STUB_REPO_NAME="Muso-AI/hydra"
  export STUB_HOUR=10
  export RELEASE_DAILY_HOUR=0
  export STUB_GH_RUN_FAIL_COUNT=99
  export STUB_GH_RUN_FAIL_MSG="synthetic-auth-failure-77ee"

  run "$SCRIPT" --repo=hydra --no-highlights
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qE "gh run list failed after 3 attempts:.*synthetic-auth-failure-77ee"
  [ "$(_run_list_call_count)" -eq 3 ]
}

@test "hydra detector: a huge gh stderr payload does not abort the retry loop before it completes" {
  # See the status-detector test of the same name above: this call site is
  # likewise nested inside detect_hydra's own `$(...)`, which the same
  # hand-testing showed shields it from the SIGPIPE. Kept as the same
  # behavior-contract regression; the real repro is the `--bootstrap` test.
  export STUB_REPO_NAME="Muso-AI/hydra"
  export STUB_HOUR=10
  export RELEASE_DAILY_HOUR=0
  export STUB_GH_RUN_FAIL_COUNT=99
  export STUB_GH_RUN_FAIL_BIGSTDERR=65536

  run "$SCRIPT" --repo=hydra --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh run list failed after 3 attempts"* ]]
  [ "$(_run_list_call_count)" -eq 3 ]
}

@test "hydra detector: a transient failure (fails twice, succeeds 3rd) is a normal, successful tick" {
  export STUB_REPO_NAME="Muso-AI/hydra"
  export STUB_HOUR=10
  export RELEASE_DAILY_HOUR=0
  export STUB_GH_RUN_FAIL_COUNT=2
  export STUB_GH_RUN_FAIL_MSG="synthetic-transient"
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=v2026.8.26\nlast_date=1970-01-01\nlast_run_at=2026-08-27T11:00:00Z\nlast_run_id=1000\n' \
    "$BASE_SHA" "$BASE_SHA" > "$HYDRA_RELEASE_STATE_DIR/announced/hydra"

  run "$SCRIPT" --repo=hydra --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARN"* ]]
  [ "$(_run_list_call_count)" -eq 3 ]
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | head -1)"
  [ -n "$tag" ]
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$MID_SHA" ]
}

# ─────────────────────────────────────────────────────────────────
# (b) stale-listing guard — status detector
# ─────────────────────────────────────────────────────────────────

@test "status detector: a listing whose newest run predates our checkpoint is nothing new, not a page" {
  # last_run_id=5000 was already announced; the listing gh hands back now
  # tops out at 1001 -- a stale/lagging replica, not a regression.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-01T00:00:00Z", "status": "completed" } ]
JSON
  export STUB_ROLLED_OUT="$SHIPPED_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26" 5000

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* || "$output" == *"lagging replica"* ]]
  [[ "$output" == *"1001"* && "$output" == *"5000"* ]]
  [[ "$output" == *"NO_REPLY"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  # The checkpoint must not move off a listing we refused to trust.
  grep -q 'last_run_id=5000' "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "status detector: when last_run_id is empty (legacy state) the stale guard is skipped" {
  # Legacy state carries only last_run_at, no last_run_id. A listing whose
  # max id is a small, suspicious-looking number must NOT be rejected as
  # stale -- there is no checkpoint to compare it against yet.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 5, "headSha": "$BASE_SHA",    "conclusion": "success", "createdAt": "2026-08-27T11:00:00Z", "status": "completed" },
  { "databaseId": 6, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-27T11:55:00Z", "status": "completed" } ]
JSON
  export STUB_ROLLED_OUT="$BASE_SHA $SHIPPED_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=v2026.8.26\nlast_run_at=2026-08-27T11:00:00Z\n' \
    "$BASE_SHA" "$BASE_SHA" > "$HYDRA_RELEASE_STATE_DIR/announced/auth"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" != *"stale"* ]]
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | head -1)"
  [ -n "$tag" ]
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$SHIPPED_SHA" ]
}

# ─────────────────────────────────────────────────────────────────
# (b) stale-listing guard — hydra detector
# ─────────────────────────────────────────────────────────────────

@test "hydra detector: a listing whose newest run predates our checkpoint announces nothing and does not page" {
  export STUB_REPO_NAME="Muso-AI/hydra"
  export STUB_HOUR=10
  export RELEASE_DAILY_HOUR=0
  # Mirrors the real 2026-09-29 incident: last_run_id=35999952562 (091a7ee95)
  # already announced; the listing gh hands back this tick tops out at
  # 34467859512 (ce80d37ca) -- a stale replica 19 days behind.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 34467859512, "headSha": "ce80d37ca0000000000000000000000000000ca", "conclusion": "success", "createdAt": "2026-09-10T00:00:00Z", "status": "completed" } ]
JSON
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  printf 'last_sha=091a7ee9500000000000000000000000000000\nlast_marker=091a7ee9500000000000000000000000000000\nlast_version=v2026.9.24\nlast_date=1970-01-01\nlast_run_at=2026-09-24T12:34:53Z\nlast_run_id=35999952562\n' \
    > "$HYDRA_RELEASE_STATE_DIR/announced/hydra"

  run "$SCRIPT" --repo=hydra --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* || "$output" == *"lagging replica"* ]]
  [[ "$output" == *"34467859512"* && "$output" == *"35999952562"* ]]
  [[ "$output" == *"NO_REPLY"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  # The checkpoint must be untouched by a listing we refused to trust.
  grep -q 'last_run_id=35999952562' "$HYDRA_RELEASE_STATE_DIR/announced/hydra"
}

# ─────────────────────────────────────────────────────────────────
# (a) capture stderr + retry — bootstrap path (the REAL SIGPIPE repro)
# ─────────────────────────────────────────────────────────────────

@test "bootstrap: a huge gh stderr payload dies with the real error instead of SIGPIPE-ing the script" {
  # This is the reachable half of the GitHub Muso QA Bot NO-GO on hydra#1031
  # @7212dcf7. Unlike gh_run_list_retry's call sites (see the two "huge gh
  # stderr" tests above -- always invoked inside a nested `$(...)`, which
  # hand-testing showed shields the whole pipeline's SIGPIPE from `set -e`),
  # this bootstrap assignment runs at the script's TOP LEVEL with no
  # enclosing command substitution, so a large stderr payload really does
  # SIGPIPE `tr` and take `set -e` down with it before `die` ever runs.
  # Reproduced upstream with a 65536-byte fixture; reproduce the same size
  # here. Pre-fix (`tr -d '\0' < "$brun_err" | head -c 300`) this crashes
  # with a bare exit 141 and none of the assertions below; post-fix
  # (`head -c 300 "$brun_err" | tr -d '\0'`) it reaches the real `die`.
  export STUB_GH_RUN_FAIL_COUNT=1
  export STUB_GH_RUN_FAIL_BIGSTDERR=65536

  run "$SCRIPT" --repo=auth --bootstrap="$MID_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read the dispatch runs"* ]]
  [[ "$output" == *"says NOTHING about whether"* ]]
}

@test "hydra detector: the REAL 2026-09-29 listing (not stale) is announced and dedupes correctly" {
  export STUB_REPO_NAME="Muso-AI/hydra"
  export STUB_HOUR=10
  export RELEASE_DAILY_HOUR=0
  # The correct, non-stale listing: newest success IS 35999952562/091a7ee95,
  # exactly the already-announced marker.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 36520745627, "headSha": "a2f49b3040000000000000000000000000000b", "conclusion": "failure", "createdAt": "2026-09-29T04:14:30Z", "status": "completed" },
  { "databaseId": 35999952562, "headSha": "091a7ee9500000000000000000000000000000", "conclusion": "success", "createdAt": "2026-09-24T12:34:53Z", "status": "completed" } ]
JSON
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  printf 'last_sha=091a7ee9500000000000000000000000000000\nlast_marker=091a7ee9500000000000000000000000000000\nlast_version=v2026.9.24\nlast_date=1970-01-01\nlast_run_at=2026-09-24T12:34:53Z\nlast_run_id=35999952562\n' \
    > "$HYDRA_RELEASE_STATE_DIR/announced/hydra"

  run "$SCRIPT" --repo=hydra --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" != *"stale"* ]]
  [[ "$output" == *"already announced"* ]]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
}
