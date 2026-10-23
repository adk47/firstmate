#!/usr/bin/env bats
# Tests for scripts/release-watch.sh — the prod-release detector that cuts
# tags and announces them in #releases.
#
# PATH-shadows `gh`, `openclaw` and `muso` so the suite NEVER touches
# GitHub, the gateway, or Slack for real. `git` is deliberately NOT stubbed:
# the tag/ancestry/range logic is the part most worth testing, and a stubbed
# git would test the stub instead. A local bare repo stands in for origin.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
# Set per-test by _build_script_tree. auth ships DISABLED (its H-DevOps
# status writer is not live yet) but is this suite's fixture repo, so tests
# run against a private copy of the REAL config with that one field flipped.
SCRIPT=""

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"

  export HYDRA_RELEASE_STATE_DIR="$TEST_TMPDIR/state"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR"

  # Keep the fallback path fast: the timeout test must not sleep for 240s.
  export RELEASE_HIGHLIGHTS_TIMEOUT=5
  export RELEASES_SLACK_CHANNEL="C0TESTREL"

  # slack-notify.sh refuses to send without a bot token, and falls back to
  # reading /etc/openclaw/main.env. Point both at the sandbox so the suite
  # exercises the real send path against the stub instead of silently
  # skipping the post (which would make every "did it announce?" assertion
  # pass for the wrong reason).
  export MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-test-token"
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/main.env"; : > "$MUSO_SLACK_ENV_FILE"

  # Retries on a failed `gh run list` must not sleep for real in tests.
  export RELEASE_GH_RETRY_DELAYS="0 0"

  export STUB_GH_ARGV="$TEST_TMPDIR/gh-argv";           : > "$STUB_GH_ARGV"
  export STUB_CURL_ARGV="$TEST_TMPDIR/curl-argv"; : > "$STUB_CURL_ARGV"
  export STUB_OPENCLAW_CALLS="$TEST_TMPDIR/openclaw-calls"; : > "$STUB_OPENCLAW_CALLS"
  export STUB_MUSO_ARGV="$TEST_TMPDIR/muso-argv";       : > "$STUB_MUSO_ARGV"
  export STUB_RELEASE_CREATE="$TEST_TMPDIR/release-create"; : > "$STUB_RELEASE_CREATE"

  export STUB_BUMP_JSON="$TEST_TMPDIR/bumps.json"
  export STUB_RUNS_JSON="$TEST_TMPDIR/runs.json"
  export STUB_HIGHLIGHTS_WRITE=""   # non-empty => the agent turn "succeeds"
  export STUB_HL_FAIL=""
  export STUB_HL_CONTENT=""
  export STUB_MUSO_FAIL=""
  export STUB_GH_FAIL=""
  export STUB_GH_RAW_STDOUT=""
  export STUB_GH_STDERR_NOTICE=""
  export STUB_RELEASE_MISSING=""
  # Which shas H-DevOps has confirmed rolled out. Set per test.
  export STUB_ROLLED_OUT=""
  export STUB_ROLLOUT_FAILED=""
  export STUB_ROLLOUT_RETRIED=""
  export STUB_ROLLOUT_PENDING=""
  _build_script_tree
  export STUB_REPO_NAME=""
  export STUB_REPO_VIEW_FAIL=""
  # Point the highlights call at a key file that exists so the stubbed curl
  # is actually reached rather than short-circuited by the missing-key guard.
  export OPENROUTER_API_KEY="test-key"

  export STUB_HOUR=""   # when set, `date +%H` returns it (Rome-hour control)

  _make_origin
  export STUB_MKTEMP_FAIL_STATE=""
  # Resolved BEFORE PATH is shadowed, so the stub can still reach the real
  # binary (its location differs between macOS and the Linux CI image).
  REAL_MKTEMP="$(command -v mktemp)"; export REAL_MKTEMP
  _write_date_stub
  _write_mktemp_stub
  _write_gh_stub
  _write_curl_stub
  _write_openclaw_tripwire
  _write_muso_stub
  PATH="$STUBBIN:$PATH"; export PATH
}

teardown() { rm -rf "$TEST_TMPDIR"; }

_build_script_tree() {
  mkdir -p "$TEST_TMPDIR/scripts/lib"
  cp "$HYDRA_REPO/scripts/release-watch.sh" "$HYDRA_REPO/scripts/release.sh" \
     "$HYDRA_REPO/scripts/release-digest.sh" "$TEST_TMPDIR/scripts/"
  cp "$HYDRA_REPO/scripts/lib/release-announce.sh" \
     "$HYDRA_REPO/scripts/lib/release_blockkit.py" \
     "$HYDRA_REPO/scripts/lib/slack-notify.sh" "$TEST_TMPDIR/scripts/lib/"
  # '#' delimiter: the table's own separator is '|'.
  sed 's#^auth|Muso-AI/auth|0|#auth|Muso-AI/auth|1|#' \
    "$HYDRA_REPO/scripts/lib/release-repos.sh" > "$TEST_TMPDIR/scripts/lib/release-repos.sh"
  grep -q '^auth|Muso-AI/auth|1|' "$TEST_TMPDIR/scripts/lib/release-repos.sh" \
    || { echo "FIXTURE: could not enable the auth row" >&2; return 1; }
  SCRIPT="$TEST_TMPDIR/scripts/release-watch.sh"
}

# A bare repo that stands in for origin, plus four commits and a baseline
# tag so the range logic has something real to walk.
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

# Only +%H and +%F are intercepted, and only when STUB_HOUR is set; every
# other call (state_put's -u timestamp, mktemp templates) hits real date.
_write_date_stub() {
  cat > "$STUBBIN/date" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_HOUR:-}" ]; then
  for a in "$@"; do
    case "$a" in
      +%H) printf '%s\n' "$STUB_HOUR"; exit 0 ;;
    esac
  done
fi
exec /bin/date "$@"
STUB
  chmod +x "$STUBBIN/date"
}

# Simulates a state directory that cannot be written (full or read-only
# filesystem). It must be a STUB and not `chmod 000`: CI runs bats as ROOT,
# and root writes straight through an unwritable directory, so a permission
# bit would make this test pass for the wrong reason on a laptop and not
# test anything at all in CI. Only the state file's temp sibling fails --
# every other mktemp in the script must keep working, or the run would die
# somewhere else and the assertion would prove nothing.
_write_mktemp_stub() {
  cat > "$STUBBIN/mktemp" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_MKTEMP_FAIL_STATE:-}" ]; then
  for a in "$@"; do
    case "$a" in
      */announced/*) echo "mktemp: cannot create: Read-only file system" >&2; exit 1 ;;
    esac
  done
fi
exec "$REAL_MKTEMP" "$@"
STUB
  chmod +x "$STUBBIN/mktemp"
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
    # repos/<o>/<r>/commits/<sha>/status -> the authoritative rollout record.
    # $STUB_ROLLED_OUT lists the shas H-DevOps has confirmed live.
    # Real `gh` applies --jq to the response; the stub must too, or the
    # caller gets raw JSON where it expects the filtered value.
    filter=""; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && filter="$a"; prev="$a"; done
    sha="$(printf '%s' "$2" | sed -n 's#.*/commits/\([0-9a-f]*\)/status#\1#p')"
    # repos/<o>/<r>/compare/<base>...<head> -> {"status": ...}. Driven by
    # $STUB_COMPARE_STATUS; unset behaves like a failing call, so a test that
    # does not opt in can never be "covered" by accident. The argv is already
    # recorded above, so a test can assert which two shas were compared.
    case "$2" in
      */compare/*)
        [ -n "$STUB_COMPARE_STATUS" ] || { echo "gh: compare not stubbed" >&2; exit 1; }
        body="{\"status\":\"$STUB_COMPARE_STATUS\"}"
        if [ -n "$filter" ]; then printf '%s' "$body" | jq -r "$filter"; else printf '%s\n' "$body"; fi
        exit 0 ;;
    esac
    if [ -n "$sha" ]; then
      if printf '%s' "$STUB_ROLLED_OUT" | tr ' ' '\n' | grep -qx "$sha"; then
        body='{"state":"success","total_count":1,"statuses":[{"state":"success","context":"H-DevOps / deploy","description":"Rollout to muso-prod (success)"}]}'
      elif printf '%s' "$STUB_ROLLOUT_PENDING" | tr ' ' '\n' | grep -qx "$sha"; then
        body='{"state":"pending","total_count":1,"statuses":[{"state":"pending","context":"H-DevOps / deploy","created_at":"2026-08-27T11:59:00Z"}]}'
      elif printf '%s' "$STUB_ROLLOUT_RETRIED" | tr ' ' '\n' | grep -qx "$sha"; then
        # An OLDER success followed by a NEWER failure, deliberately listed
        # newest-last so a naive `first` would also pick wrong.
        body='{"state":"failure","total_count":2,"statuses":[{"state":"success","context":"H-DevOps / deploy","created_at":"2026-08-27T11:00:00Z"},{"state":"failure","context":"H-DevOps / deploy","created_at":"2026-08-27T12:00:00Z"}]}'
      elif printf '%s' "$STUB_ROLLOUT_FAILED" | tr ' ' '\n' | grep -qx "$sha"; then
        body='{"state":"failure","total_count":1,"statuses":[{"state":"failure","context":"H-DevOps / deploy","description":"Rollout to muso-prod (failure)"}]}'
      else
        body='{"state":"pending","total_count":0,"statuses":[]}'
      fi
    else
      body='[]'
    fi
    if [ -n "$filter" ]; then printf '%s' "$body" | jq -r "$filter"; else printf '%s\n' "$body"; fi
    exit 0 ;;
  run)
    # A zero-exit response whose stdout is NOT a JSON array. Real gh can do
    # this; without a seam the bootstrap's shape guard is untestable and so
    # is dead weight (mutation B2 stayed green until this existed).
    if [ -n "${STUB_GH_RAW_STDOUT:-}" ]; then
      printf '%s\n' "$STUB_GH_RAW_STDOUT"; exit 0
    fi
    # gh routinely writes NOTICES to stderr while succeeding. Capturing with
    # `2>&1` folds those into the JSON and corrupts a perfectly good
    # listing, so the seam exists to keep that regression caught.
    if [ -n "${STUB_GH_STDERR_NOTICE:-}" ]; then
      echo "gh: a note about authentication" >&2
    fi
    # Real `gh run list` returns the NEWEST runs and truncates at --limit.
    # The stub MUST model that: a stub that always returns everything makes
    # the window-reach guard untestable and every backlog assertion pass for
    # the wrong reason.
    lim=""; prev=""
    for a in "$@"; do [ "$prev" = "--limit" ] && lim="$a"; prev="$a"; done
    if [ -n "$lim" ]; then
      jq -c "sort_by(.databaseId) | reverse | .[0:$lim]" "$STUB_RUNS_JSON"
    else
      cat "$STUB_RUNS_JSON"
    fi
    exit 0 ;;
  repo)
    case "$2" in
      clone) git clone --quiet "$ORIGIN" "$4"; exit $? ;;
      view)
        [ -n "$STUB_REPO_VIEW_FAIL" ] && { echo "gh: could not resolve repo" >&2; exit 1; }
        echo "${STUB_REPO_NAME:-Muso-AI/auth}"; exit 0 ;;
    esac ;;
  release)
    if [ "$2" = "create" ]; then printf '%s\n' "$*" >> "$STUB_RELEASE_CREATE"; exit 0; fi
    if [ "$2" = "view" ]; then
      [ -n "$STUB_RELEASE_MISSING" ] && exit 1
      grep -q -- "$3" "$STUB_RELEASE_CREATE" 2>/dev/null && exit 0
      exit 1
    fi ;;
  auth) exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUBBIN/gh"
}

# The highlights step is now a direct, tool-less HTTP call. Stub `curl` so
# the suite never reaches the network, and so a test can make it fail.
_write_curl_stub() {
  cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CURL_ARGV"
[ -n "$STUB_HL_FAIL" ] && { echo "curl: failed" >&2; exit 7; }
if [ -n "$STUB_HIGHLIGHTS_WRITE" ]; then
  # \\n so printf emits a literal backslash-n: a REAL newline inside a JSON
  # string is invalid JSON and jq would return empty.
  if [ -n "$STUB_HL_CONTENT" ]; then
    jq -nc --arg c "$STUB_HL_CONTENT" '{choices:[{message:{content:$c}}]}'
    exit 0
  fi
  printf '{"choices":[{"message":{"content":"credits now show up right after you claim them\\nthe roster stopped spinning forever"}}]}'
  exit 0
fi
printf '{"choices":[{"message":{"content":""}}]}'
exit 0
STUB
  chmod +x "$STUBBIN/curl"
}

_write_openclaw_tripwire() {
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
# Capture the rendered payload so tests can assert on the real message.
prev=""
for a in "$@"; do
  if [ "$prev" = "--blocks-file" ]; then cp "$a" "$TEST_TMPDIR/posted.json"; fi
  prev="$a"
done
[ -n "$STUB_MUSO_FAIL" ] && exit 1
exit 0
STUB
  chmod +x "$STUBBIN/muso"
}

# The tag glob release.sh will actually produce today. Hardcoding a date
# here made every one of these assertions expire at midnight UTC -- which is
# exactly how this was found. Mirrors release.sh's `v$(date -u +%Y.%-m.%-d)`.
_today_tag_glob() { printf 'v%s*' "$(date -u +%Y.%-m.%-d)"; }

# _rolled_out <sha>...   — H-DevOps confirmed these shas live.
# _rollout_failed <sha>… — H-DevOps recorded a FAILED rollout for these.
# A sha in neither list has no rollout record at all (still in flight).
_rolled_out()     { export STUB_ROLLED_OUT="$*"; }
_rollout_failed() { export STUB_ROLLOUT_FAILED="$*"; }

# A successful prod dispatch run for sha $1 at $2 (ISO date). By default the
# sha is also marked as CONFIRMED ROLLED OUT, since that is the ordinary case;
# a test that needs "dispatched but never reached prod" calls _rolled_out
# afterwards to override.
# _set_runs <sha> <iso-date> [run-id]
_set_runs() {
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": ${3:-1001}, "headSha": "$1", "conclusion": "success", "createdAt": "$2", "status": "completed" } ]
JSON
  export STUB_ROLLED_OUT="$1"
}

# _rolled_out <sha>...  — mark these shas as confirmed live by H-DevOps.
_rolled_out() { export STUB_ROLLED_OUT="$*"; }

# A successful prod dispatch run for sha $1 at $2 (ISO date).
# A backlog: the checkpoint run itself (1000 @ BASE_SHA), then MID_SHA at
# 1001, then $1 redeploys of SHIPPED_SHA. Every sha is REAL, so a wrong pick
# still produces a cuttable release -- the assertion then distinguishes
# "announced the right one" from "silently skipped one", which is the whole
# point. All are marked rolled out.
_set_backlog_runs() {
  local extra="$1" id=1002 rows
  rows="{\"databaseId\":1000,\"headSha\":\"$BASE_SHA\",\"conclusion\":\"success\",\"createdAt\":\"2026-08-27T11:00:00Z\",\"status\":\"completed\"}"
  rows="$rows,{\"databaseId\":1001,\"headSha\":\"$MID_SHA\",\"conclusion\":\"success\",\"createdAt\":\"2026-08-27T11:30:00Z\",\"status\":\"completed\"}"
  while [ "$id" -lt $((1002 + extra)) ]; do
    rows="$rows,{\"databaseId\":$id,\"headSha\":\"$SHIPPED_SHA\",\"conclusion\":\"success\",\"createdAt\":\"2026-08-27T12:00:00Z\",\"status\":\"completed\"}"
    id=$((id + 1))
  done
  printf '[%s]\n' "$rows" > "$STUB_RUNS_JSON"
  export STUB_ROLLED_OUT="$BASE_SHA $MID_SHA $SHIPPED_SHA"
}

# _seed_state <sha> <run_at>  — the last announced release.
_seed_state() {
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=%s\nannounced_at=seed\nlast_run_at=%s\nlast_run_id=%s\n' \
    "$1" "$1" "${3:-v2026.8.26}" "${2:-2026-08-27T11:00:00Z}" "${4:-1000}" \
    > "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

# ─────────────────────────────────────────────────────────────────

@test "nothing shipped: prints NO_REPLY, exits 0, tags nothing" {
  # The listing reaches the checkpoint run itself (id 1000) and nothing
  # newer -- a real "nothing new" tick. It must NOT be an empty array: a
  # repo with an established checkpoint always has at least that run in its
  # history, so a genuinely empty listing is the malformed/unmeasured case
  # covered separately below, not this one.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1000, "headSha": "$BASE_SHA", "conclusion": "success", "createdAt": "2026-08-27T11:00:00Z", "status": "completed" } ]
JSON
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_REPLY"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
  run git -C "$ORIGIN" tag -l
  [ -z "$output" ] || [ "$output" = "v2026.8.26" ]
}

@test "status detector refuses an EMPTY run listing as unmeasured, not as nothing shipped" {
  # QA probe B (MUS-1343): a repo wired into release-watch deploys, so a
  # literally empty listing on its production branch is never a fact about
  # production -- it must not render as the quiet "nothing shipped" tick.
  echo '[]' > "$STUB_RUNS_JSON"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"came back EMPTY"* ]]
  [[ "$output" != *"NO_REPLY"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

@test "status detector refuses an UNPARSEABLE run listing, it does not read it as nothing shipped" {
  # QA probe A (MUS-1343): a zero-exit gh response carrying a GitHub error
  # body must not reach jq and fail open into "no confirmed prod release".
  export STUB_GH_RAW_STDOUT='{"message":"Bad credentials"}'
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a JSON array"* ]]
  [[ "$output" == *"Bad credentials"* ]]
  [[ "$output" != *"NO_REPLY"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

@test "status detector catches TRUNCATED JSON with the same shape guard, not a downstream jq crash" {
  # QA probe C (MUS-1343): a truncated body is still a zero-exit, non-array
  # response and must be caught by the same guard as probe A, not left to
  # crash a later jq call with no [release-watch] context.
  export STUB_GH_RAW_STDOUT='[{"databaseId":123,"headSha":"dead'
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a JSON array"* ]]
  [[ "$output" != *"jq: error"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

@test "new bump: pins the dispatch sha, not whatever main has drifted to" {
  # main is at SHIPPED_SHA, but the deploy that produced this bump shipped
  # MID_SHA. The release must describe MID_SHA.
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  # The tag landed on the pinned commit, not on main's tip.
  tagged="$(git -C "$ORIGIN" rev-list -n1 "$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | head -1)")"
  [ "$tagged" = "$MID_SHA" ]
  [ "$tagged" != "$SHIPPED_SHA" ]
}

@test "changelog covers only the shipped range" {
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  body="$(cat "$TEST_TMPDIR/posted.json")"
  # #2 shipped; #3 merged after the deploy and must NOT be claimed.
  [[ "$body" == *"stop the roster spinning forever"* ]]
  [[ "$body" != *"show credits right after a claim"* ]]
}

@test "same signal twice: second run is a no-op, no duplicate tag or post" {
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  first_tags="$(git -C "$ORIGIN" tag -l | wc -l | tr -d ' ')"
  first_posts="$(wc -l < "$STUB_MUSO_ARGV" | tr -d ' ')"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  # Nothing is pending after the marker, so the tick drains nothing.
  [[ "$output" == *"no confirmed prod release found"* || "$output" == *"already announced"* ]]
  [ "$(git -C "$ORIGIN" tag -l | wc -l | tr -d ' ')" = "$first_tags" ]
  [ "$(wc -l < "$STUB_MUSO_ARGV" | tr -d ' ')" = "$first_posts" ]
}

@test "agent turn times out: the release is STILL announced, and says so" {
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  export STUB_HIGHLIGHTS_WRITE=""   # the turn never writes the file

  run "$SCRIPT" --repo=auth
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/posted.json" ]
  body="$(cat "$TEST_TMPDIR/posted.json")"
  [[ "$body" == *"highlights unavailable"* ]]
  # The deterministic sections must carry the content instead.
  [[ "$body" == *"Fixes"* ]]
}

@test "agent turn succeeds: highlights replace the commit-log rendering" {
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  export STUB_HIGHLIGHTS_WRITE=1

  run "$SCRIPT" --repo=auth
  [ "$status" -eq 0 ]
  body="$(cat "$TEST_TMPDIR/posted.json")"
  [[ "$body" == *"What's new"* ]]
  [[ "$body" == *"credits now show up right after you claim them"* ]]
  [[ "$body" != *"highlights unavailable"* ]]
}

@test "gateway down: dispatch fails, release still announced via fallback" {
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  export STUB_OPENCLAW_FAIL=1

  run "$SCRIPT" --repo=auth
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/posted.json" ]
  [[ "$(cat "$TEST_TMPDIR/posted.json")" == *"highlights unavailable"* ]]
}

@test "re-run of an older deploy is refused, not announced as new" {
  # A workflow re-run keeps its old headSha but gets a fresh createdAt.
  _set_runs "$BASE_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$MID_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not descend from"* ]]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
}

@test "never released and no prior tag: refuses to publish full history" {
  # A bare origin with commits but NO tags, and no recorded state.
  git -C "$TEST_TMPDIR/seed" push --quiet --delete origin v2026.8.26
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing to publish full history"* ]]
  [[ "$output" == *"--bootstrap"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

@test "a redeploy of the same sha is never announced twice" {
  # Re-running a deploy produces a NEW dispatch run carrying the SAME sha.
  # The rollout record is per-sha, so the marker matches what we already
  # announced and the tick must stay silent.
  _set_runs "$MID_SHA" "2026-08-27T12:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$MID_SHA" "2026-08-27T12:00:00Z" "v2026.8.27"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"already announced"* ]]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

@test "disabled repos (mobile) are skipped, not announced" {
  run "$SCRIPT" --repo=ios-app --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"Phase 2"* || "$output" == *"not enabled"* ]]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
}

@test "dry-run emits a valid payload and changes nothing" {
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run --separate-stderr "$SCRIPT" --repo=auth --dry-run --no-highlights
  [ "$status" -eq 0 ]
  # $output is stdout only here: the payload is the machine channel, and
  # the human log lines land in $stderr.
  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
  [ ! -s "$STUB_RELEASE_CREATE" ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  # State must be untouched: a dry run that advanced the baseline would
  # silently swallow the next real release.
  grep -q "last_marker=$BASE_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "unset channel fails closed: nothing is tagged or published" {
  # A misconfigured channel must not quietly cut tags nobody ever sees.
  # Tags cannot be un-cut, so this is the one config error worth refusing on.
  unset RELEASES_SLACK_CHANNEL
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"RELEASES_SLACK_CHANNEL is unset"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
  [ -z "$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)")" ]
}

@test "bootstrap needs no channel: it seeds a baseline and posts nothing" {
  unset RELEASES_SLACK_CHANNEL
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"

  run "$SCRIPT" --repo=auth --bootstrap="$MID_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline seeded"* ]]
  grep -q "last_sha=$MID_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

# ── cadence: daily ──────────────────────────────────────────────
# hydra is `daily` in the real table. These drive the same gate through
# the `auth` fixture by overriding the table entry in a temp copy.
_make_auth_daily() {
  sed -i.bak 's#^auth|\(.*\)|per-deploy|#auth|\1|daily|#' \
    "$TEST_TMPDIR/scripts/lib/release-repos.sh"
  rm -f "$TEST_TMPDIR/scripts/lib/release-repos.sh.bak"
  grep -q '^auth|.*|daily|' "$TEST_TMPDIR/scripts/lib/release-repos.sh" \
    || { echo "FIXTURE: cadence rewrite failed" >&2; return 1; }
  DAILY_SCRIPT="$SCRIPT"
}
@test "daily cadence: holds before the configured hour, does not tag" {
  _make_auth_daily
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  # Deterministic: pretend it is 03:00 Rome, well before the 08:00 gate.
  export STUB_HOUR=03
  export RELEASE_DAILY_HOUR=8

  run "$DAILY_SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"holding"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  # Held, NOT recorded. The marker must stay stale so the next tick retries,
  # and -- the invariant that actually protects the roll-up -- last_sha must
  # NOT advance, or the next cut would silently skip everything held today.
  grep -q "last_marker=$BASE_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  grep -q "last_sha=$BASE_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "daily cadence: an hour like 08 does not abort as an octal literal" {
  # `(( 10#$hour < 8 ))` is the guard; a bare `(( 08 < 8 ))` is a fatal
  # "value too great for base" under set -e. Pin the gate to 08 and assert
  # the script completes normally either way.
  _make_auth_daily
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  export RELEASE_DAILY_HOUR=08

  run "$DAILY_SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" != *"value too great"* ]]
  [[ "$output" != *"invalid arithmetic"* ]]
}

@test "daily cadence: at most one release per day, second tick holds" {
  _make_auth_daily
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  export RELEASE_DAILY_HOUR=0
  export STUB_HOUR=10

  run "$DAILY_SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/posted.json" ]
  tags_after_first="$(git -C "$ORIGIN" tag -l | wc -l | tr -d ' ')"
  grep -q "last_date=" "$HYDRA_RELEASE_STATE_DIR/announced/auth"

  # A second, genuinely NEW deploy the same day must not produce a 2nd post.
  _set_runs "$SHIPPED_SHA" "2026-08-27T17:55:00Z" 1002
  rm -f "$TEST_TMPDIR/posted.json"

  run "$DAILY_SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"already announced today"* ]]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  [ "$(git -C "$ORIGIN" tag -l | wc -l | tr -d ' ')" = "$tags_after_first" ]
  # The held second deploy must leave last_sha at what was actually
  # announced, so tomorrow's roll-up still covers it.
  grep -q "last_sha=$MID_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "daily cadence: the next day rolls up everything held" {
  _make_auth_daily
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  # Pretend yesterday's cut stopped at BASE_SHA.
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=%s\nlast_date=1970-01-01\nlast_run_at=%s\nlast_run_id=1000\n' \
    "$BASE_SHA" "$BASE_SHA" "v2026.8.26" "2026-08-27T11:00:00Z" \
    > "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  export RELEASE_DAILY_HOUR=0
  export STUB_HOUR=10

  # Two deploys happened since; the roll-up must cover BOTH commits.
  _set_runs "$SHIPPED_SHA" "2026-08-27T11:55:00Z"
  run "$DAILY_SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  body="$(cat "$TEST_TMPDIR/posted.json")"
  [[ "$body" == *"stop the roster spinning forever"* ]]
  [[ "$body" == *"show credits right after a claim"* ]]
}

# ── gaps found by the pre-PR review ─────────────────────────────

@test "the GitHub release is actually created, with this version" {
  # Regression guard: every earlier assertion on STUB_RELEASE_CREATE was
  # NEGATIVE, so deleting release.sh's `gh release create` left all tests
  # green. Assert the positive case.
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [ -s "$STUB_RELEASE_CREATE" ]
  grep -q 'release create' "$STUB_RELEASE_CREATE"
  # Today's version, not a literal: release.sh derives it from the clock.
  grep -qF "v$(date -u +%Y.%-m.%-d)" "$STUB_RELEASE_CREATE"
}

@test "a dispatch whose rollout is still in flight is not announced yet" {
  # The dispatch succeeded but H-DevOps has not recorded a rollout yet.
  # Must read as nothing to do, and must NOT be retired -- the grace window
  # applies only once a record can no longer plausibly arrive. Uses
  # wall-clock now, because a fixed timestamp ages past the window and this
  # test would then pass through the retire branch instead, which emits the
  # same generic "no confirmed prod release" line.
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _set_runs "$MID_SHA" "$NOW"
  _rolled_out ""
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollout unresolved"* ]]
  [[ "$output" == *"state='none'"* ]]
  [[ "$output" != *"INDETERMINATE"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
}

@test "a failed Slack post still advances state, so the next tick does not re-cut" {
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  export STUB_MUSO_FAIL=1

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"Slack post failed"* ]]
  grep -q "last_marker=$MID_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  tags_before="$(git -C "$ORIGIN" tag -l | wc -l | tr -d ' ')"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"no confirmed prod release found"* || "$output" == *"already announced"* ]]
  [ "$(git -C "$ORIGIN" tag -l | wc -l | tr -d ' ')" = "$tags_before" ]
}

@test "unreachable GitHub fails loud: non-zero, and no NO_REPLY" {
  # "Could not measure" must never render as "measured: nothing shipped".
  export STUB_GH_FAIL=1
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" != *"NO_REPLY"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

@test "an already-tagged commit is adopted, never re-cut" {
  # Simulates a tick that published then died before recording state.
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  git -C "$TEST_TMPDIR/seed" tag -a v2026.8.27 -m v2026.8.27 "$MID_SHA"
  git -C "$TEST_TMPDIR/seed" push --quiet origin v2026.8.27
  # The GitHub release exists too — this is the "published but unrecorded"
  # case, distinct from the half-published case covered below.
  echo "release create v2026.8.27" > "$STUB_RELEASE_CREATE"
  tags_before="$(git -C "$ORIGIN" tag -l | wc -l | tr -d ' ')"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"Adopting, not re-cutting"* ]]
  [ "$(git -C "$ORIGIN" tag -l | wc -l | tr -d ' ')" = "$tags_before" ]
  grep -q 'last_version=v2026.8.27' "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  [ ! -f "$TEST_TMPDIR/posted.json" ]
}

@test "an unwritable state dir fails the tick loud, it never starves silently" {
  # process_repo runs as `process_repo ... || FAILED=1`, and bash suppresses
  # set -e for the ENTIRE body of a function on the left of `||`. So an
  # unchecked state write cannot stop anything: the release is announced,
  # last_run_id stays stale, and every later tick re-selects this same
  # release, re-adopts it, and returns 0 -- starving newer releases forever
  # while systemd reports a healthy timer. The tick must go non-zero.
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  export STUB_MKTEMP_FAIL_STATE=1

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not be recorded"* ]]
  # The release was already public by then, so it must STILL be announced:
  # returning early would leave the next tick adopting the tag and recording
  # it without ever posting, a permanent silent gap in the channel.
  [ -f "$TEST_TMPDIR/posted.json" ]
}

@test "an unwritable state dir fails the ADOPT branch loud too" {
  # The adopt branch ends in an unconditional `return 0`, so a swallowed
  # state write here is the exact shape that starves the queue: nothing is
  # published, nothing is posted, and the tick claims success forever.
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  git -C "$TEST_TMPDIR/seed" tag -a v2026.8.27 -m v2026.8.27 "$MID_SHA"
  git -C "$TEST_TMPDIR/seed" push --quiet origin v2026.8.27
  echo "release create v2026.8.27" > "$STUB_RELEASE_CREATE"
  export STUB_MKTEMP_FAIL_STATE=1

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"Adopting, not re-cutting"* ]]
}

@test "a backlog deeper than one window is not silently skipped" {
  # `gh run list` returns the NEWEST runs, so the window is a tail. With more
  # unannounced releases than fit in it, every visible run looks new: the
  # detector announced the oldest run it could SEE and checkpointed past it,
  # burying every release below the window with nothing said. Here run 1001
  # (MID_SHA) sits below a 3-run window, so it must still be the one picked.
  export RELEASE_RUN_WINDOW=3
  export RELEASE_RUN_WINDOW_MAX=50
  _set_backlog_runs 8
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not reach the checkpoint"* ]]
  # Oldest-first, so the release below the window wins -- NOT the newest.
  grep -q "last_sha=$MID_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  run grep -q "last_sha=$SHIPPED_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  [ "$status" -ne 0 ]
}

@test "a backlog deeper than the widest window fails loud, it never guesses" {
  # Past the escalation ceiling the watcher cannot prove what it is missing.
  # Announcing the oldest visible run would bury the rest; skipping is worse.
  # So the tick fails, and says how to re-seed.
  export RELEASE_RUN_WINDOW=3
  export RELEASE_RUN_WINDOW_MAX=5
  _set_backlog_runs 8
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"would be skipped silently"* ]]
  [[ "$output" == *"--bootstrap"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  # The checkpoint must NOT move: advancing it here is the very data loss
  # this branch exists to prevent.
  grep -q "last_sha=$BASE_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "a window that DOES reach the checkpoint does not widen needlessly" {
  # The guard must not turn every ordinary tick into a second, larger fetch.
  export RELEASE_RUN_WINDOW=50
  export RELEASE_RUN_WINDOW_MAX=500
  _set_backlog_runs 2
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" != *"did not reach the checkpoint"* ]]
  [ "$(grep -c 'run list' "$STUB_GH_ARGV")" -eq 1 ]
}

@test "a non-numeric RELEASE_RUN_WINDOW fails closed, it does not coerce to zero" {
  # These knobs are compared with `-ge`, and bash resolves a variable's value
  # recursively inside arithmetic, so a non-numeric setting coerces toward
  # zero rather than erroring.
  export RELEASE_RUN_WINDOW=banana
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"RELEASE_RUN_WINDOW"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

@test "a ceiling below the starting window is rejected, not silently inverted" {
  export RELEASE_RUN_WINDOW=100
  export RELEASE_RUN_WINDOW_MAX=10
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not be smaller"* ]]
}

@test "a dry run never dispatches an agent turn" {
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --dry-run
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_OPENCLAW_ARGV" ]
}

@test "a hostile commit subject cannot broadcast-ping the channel" {
  # <!channel> in author-controlled text must reach Slack escaped.
  git -C "$TEST_TMPDIR/seed" commit --quiet --allow-empty     -m 'fix(api): reject <!channel> and a&b <tag> (#99)'
  hostile="$(git -C "$TEST_TMPDIR/seed" rev-parse HEAD)"
  git -C "$TEST_TMPDIR/seed" push --quiet origin main
  _set_runs "$hostile" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  body="$(cat "$TEST_TMPDIR/posted.json")"
  [[ "$body" != *'<!channel>'* ]]
  [[ "$body" == *'&lt;!channel&gt;'* ]]
  [[ "$body" == *'a&amp;b'* ]]
}

# ── findings from the QA bot's pre-merge review ─────────────────

@test "a tag with no GitHub release is NOT adopted — it fails loud" {
  # release.sh pushes the tag and THEN creates the release, so the tag can
  # exist while the release does not. Adopting on the tag alone would record
  # that half-published state as done and permanently skip both the missing
  # release and the announcement.
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  git -C "$TEST_TMPDIR/seed" tag -a v2026.8.27 -m v2026.8.27 "$MID_SHA"
  git -C "$TEST_TMPDIR/seed" push --quiet origin v2026.8.27
  export STUB_RELEASE_MISSING=1

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO GitHub release"* ]]
  [[ "$output" == *"gh release create"* ]]
  # State must NOT advance: the release is genuinely unpublished.
  grep -q "last_marker=$BASE_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "the adoption branch does not mutate state during a dry run" {
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  git -C "$TEST_TMPDIR/seed" tag -a v2026.8.27 -m v2026.8.27 "$MID_SHA"
  git -C "$TEST_TMPDIR/seed" push --quiet origin v2026.8.27
  echo "release create v2026.8.27" > "$STUB_RELEASE_CREATE"   # release exists

  run "$SCRIPT" --repo=auth --dry-run --no-highlights
  [ "$status" -eq 0 ]
  # A dry run that advanced the baseline would make a later live tick skip
  # a release that was never announced.
  grep -q "last_marker=$BASE_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  grep -q "last_sha=$BASE_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "a non-numeric RELEASE_DAILY_HOUR fails closed, never opens the gate" {
  # Bash arithmetic resolves a variable's VALUE recursively: an unvalidated
  # non-numeric hour makes the comparison evaluate false (gate opens early)
  # and a crafted value can run a command substitution.
  export RELEASE_DAILY_HOUR=abc
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an integer hour 0-23"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

@test "an out-of-range RELEASE_DAILY_HOUR is rejected too" {
  export RELEASE_DAILY_HOUR=99
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an integer hour 0-23"* ]]
}

@test "a dispatch that never rolled out is skipped, not mis-attributed" {
  # Dispatch A succeeded but its ROLLOUT failed, so no rollout record exists
  # for A. Dispatch B succeeded and rolled out. The release is B — and A's
  # sha must never be announced in B's place.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$MID_SHA",     "conclusion": "success", "createdAt": "2026-08-27T11:55:00Z", "status": "completed" },
  { "databaseId": 1002, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-27T11:58:00Z", "status": "completed" } ]
JSON
  _rolled_out "$SHIPPED_SHA"
  _rollout_failed "$MID_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | head -1)"
  [ -n "$tag" ]
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$SHIPPED_SHA" ]
  grep -q "last_marker=$SHIPPED_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "two rollouts between ticks are drained oldest-first, not collapsed" {
  # Both A and B rolled out between two five-minute ticks. The older must not
  # be skipped just because a newer rollout exists.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$MID_SHA",     "conclusion": "success", "createdAt": "2026-08-27T11:55:00Z", "status": "completed" },
  { "databaseId": 1002, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-27T11:58:00Z", "status": "completed" } ]
JSON
  _rolled_out "$MID_SHA $SHIPPED_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z"

  # Tick 1 drains A, the older of the two.
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  tag1="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | sort | head -1)"
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag1")" = "$MID_SHA" ]
  grep -q "last_marker=$MID_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"

  # Tick 2 drains B — it was not lost.
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  tag2="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | sort | tail -1)"
  [ "$tag2" != "$tag1" ]
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag2")" = "$SHIPPED_SHA" ]
  grep -q "last_marker=$SHIPPED_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "model output is bounded: too many, too-long bullets are clamped" {
  # The model is untrusted output. Without validation a malformed or hostile
  # response could produce an oversized Slack section or 40 bullets.
  long="$(head -c 900 < /dev/zero | tr '\0' 'x')"
  content=""
  for i in 1 2 3 4 5 6 7 8 9 10; do content="${content}bullet $i $long\n"; done
  export STUB_HL_CONTENT="$content"
  export STUB_HIGHLIGHTS_WRITE=1
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z"

  run "$SCRIPT" --repo=auth
  [ "$status" -eq 0 ]
  hl="$(ls "$HYDRA_RELEASE_STATE_DIR"/highlights/*.txt | head -1)"
  [ -s "$hl" ]
  [ "$(wc -l < "$hl" | tr -d ' ')" -le 5 ]
  while IFS= read -r line; do [ "${#line}" -le 200 ]; done < "$hl"
}

@test "the highlights step never invokes an agent runtime" {
  # It is a direct, tool-less HTTP call on purpose: commit subjects are
  # author-controlled, and an agent turn would give injected text access to
  # exec. A regression back to `openclaw cron add` must fail here.
  export STUB_HIGHLIGHTS_WRITE=1
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z"

  run "$SCRIPT" --repo=auth
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_OPENCLAW_CALLS" ]
  grep -q 'openrouter\|chat/completions' "$STUB_CURL_ARGV"
}

@test "an in-flight older rollout is waited for, never scanned past" {
  # A is older and still deploying (no rollout record yet); B rolled out
  # first. Announcing B would advance last_run_at past A, and A's real
  # production rollout would then be excluded forever.
  # A must be RECENT: a pending older than the grace window is treated as a
  # dead rollout (fails loud), which is a different case and covered
  # separately. Use wall-clock now so this stays true whenever it runs.
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$MID_SHA",     "conclusion": "success", "createdAt": "$NOW", "status": "completed" },
  { "databaseId": 1002, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "$NOW", "status": "completed" } ]
JSON
  _rolled_out "$SHIPPED_SHA"                 # only B has resolved
  export STUB_ROLLOUT_PENDING="$MID_SHA"     # A is genuinely deploying
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z"

  # Tick 1: A pending -> wait, announce nothing.
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollout unresolved"* ]]
  [[ "$output" == *"state='pending'"* ]]
  [ -z "$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)")" ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]

  # Tick 2: A's rollout lands -> A first, then B on the following tick.
  export STUB_ROLLOUT_PENDING=""
  _rolled_out "$MID_SHA $SHIPPED_SHA"
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  tag1="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | sort | head -1)"
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag1")" = "$MID_SHA" ]

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  tag2="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | sort | tail -1)"
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag2")" = "$SHIPPED_SHA" ]
}

@test "bootstrap stamps the supplied sha's dispatch, not a newer in-flight one" {
  # A newer dispatch has succeeded but is still rolling out. Stamping ITS
  # timestamp would exclude it forever once its rollout lands.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1000, "headSha": "$BASE_SHA",    "conclusion": "success", "createdAt": "2026-08-27T11:00:00Z", "status": "completed" },
  { "databaseId": 1002, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-27T11:58:00Z", "status": "completed" } ]
JSON
  _rolled_out "$BASE_SHA"

  run "$SCRIPT" --repo=auth --bootstrap="$BASE_SHA"
  [ "$status" -eq 0 ]
  grep -q 'last_run_at=2026-08-27T11:00:00Z' "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  # `run` + status, NOT `! grep`: a negated command is exempt from set -e and
  # this is not the test's last line, so `! grep` would never fail the test.
  run grep -q 'last_run_at=2026-08-27T11:58:00Z' "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  [ "$status" -ne 0 ]

  # The newer dispatch is therefore still reachable once it rolls out.
  _rolled_out "$BASE_SHA $SHIPPED_SHA"
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | head -1)"
  [ -n "$tag" ]
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$SHIPPED_SHA" ]
}

# ── the hydra row, end to end through the REAL config ───────────
# Every other test drives `auth`; the cadence tests rewrite that row rather
# than using `hydra`. That left the hydra detector branch with ZERO coverage,
# which is how a missing detect_hydra shipped past 36 green tests.

@test "the hydra row is driven end to end by its own detector" {
  export STUB_REPO_NAME="Muso-AI/hydra"
  export STUB_HOUR=10
  export RELEASE_DAILY_HOUR=0
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=v2026.8.26\nlast_date=1970-01-01\nlast_run_at=2026-08-27T11:00:00Z\nlast_run_id=1000\n' \
    "$BASE_SHA" "$BASE_SHA" > "$HYDRA_RELEASE_STATE_DIR/announced/hydra"

  run "$SCRIPT" --repo=hydra --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" != *"command not found"* ]]
  [ -f "$TEST_TMPDIR/posted.json" ]
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | head -1)"
  [ -n "$tag" ]
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$MID_SHA" ]
  grep -q "last_marker=$MID_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/hydra"
}

@test "hydra detector refuses an UNPARSEABLE run listing, it pages WITH a reason not a bare jq crash" {
  # QA probe D (MUS-1343): before this guard, detect_hydra's trailing jq
  # crashed on the bad body, and the ONLY output reaching the log was two
  # bare `jq:` lines -- an OnFailure page with no repo name and no cause.
  export STUB_REPO_NAME="Muso-AI/hydra"
  export STUB_GH_RAW_STDOUT='{"message":"API rate limit exceeded"}'
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=v2026.8.26\nlast_date=1970-01-01\nlast_run_at=2026-08-27T11:00:00Z\nlast_run_id=1000\n' \
    "$BASE_SHA" "$BASE_SHA" > "$HYDRA_RELEASE_STATE_DIR/announced/hydra"

  run "$SCRIPT" --repo=hydra --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"[release-watch] WARN:"* ]]
  [[ "$output" == *"not a JSON array"* ]]
  [[ "$output" == *"API rate limit exceeded"* ]]
  [[ "$output" != *"Cannot index string with string"* ]]
}

@test "hydra detector refuses an EMPTY run listing as unmeasured, not as nothing shipped" {
  # QA probe E (MUS-1343): hydra deploys itself, so an empty listing on its
  # own prod branch is never a fact about production -- it must not render
  # as the quiet "nothing shipped" tick the way it did before this guard.
  export STUB_REPO_NAME="Muso-AI/hydra"
  echo '[]' > "$STUB_RUNS_JSON"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=v2026.8.26\nlast_date=1970-01-01\nlast_run_at=2026-08-27T11:00:00Z\nlast_run_id=1000\n' \
    "$BASE_SHA" "$BASE_SHA" > "$HYDRA_RELEASE_STATE_DIR/announced/hydra"

  run "$SCRIPT" --repo=hydra --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"came back EMPTY"* ]]
  [[ "$output" != *"NO_REPLY"* ]]
}

@test "both detectors agree on disposition for an identical empty listing" {
  # AC5 (MUS-1343): the status and hydra detectors used to behave
  # OPPOSITELY on the same bad input -- status swallowed it (NO_REPLY, exit
  # 0), hydra paged over it with no explanation. Both must now refuse it the
  # same way: non-zero, warned, never NO_REPLY.
  echo '[]' > "$STUB_RUNS_JSON"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"
  run "$SCRIPT" --repo=auth --no-highlights
  status_rc="$status"; status_out="$output"

  export STUB_REPO_NAME="Muso-AI/hydra"
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=v2026.8.26\nlast_date=1970-01-01\nlast_run_at=2026-08-27T11:00:00Z\nlast_run_id=1000\n' \
    "$BASE_SHA" "$BASE_SHA" > "$HYDRA_RELEASE_STATE_DIR/announced/hydra"
  run "$SCRIPT" --repo=hydra --no-highlights
  hydra_rc="$status"; hydra_out="$output"

  [ "$status_rc" -ne 0 ]
  [ "$hydra_rc" -ne 0 ]
  [[ "$status_out" != *"NO_REPLY"* ]]
  [[ "$hydra_out" != *"NO_REPLY"* ]]
  [[ "$status_out" == *"WARN"* ]]
  [[ "$hydra_out" == *"WARN"* ]]
}

@test "every configured repo resolves its detector — no missing functions" {
  # Structural guard: walk EVERY row in the real table and assert the tick
  # completes without an unresolved helper. Catches a detector that is
  # referenced but never defined, for any row, without needing a bespoke
  # fixture per repo.
  echo '[]' > "$STUB_RUNS_JSON"
  for k in $(bash -c "source '$HYDRA_REPO/scripts/lib/release-repos.sh'; release_repo_keys"); do
    run "$SCRIPT" --repo="$k" --dry-run --no-highlights
    [[ "$output" != *"command not found"* ]] || {
      echo "row '$k' has an unresolved helper: $output" >&2
      return 1
    }
    [[ "$output" != *"unknown detector"* ]] || {
      echo "row '$k' names a detector with no branch: $output" >&2
      return 1
    }
  done
}

@test "a retried rollout resolves to the newest status, not a stale success" {
  # Same sha, two entries for the same context: an older success and a newer
  # failure. Selecting by position rather than by timestamp would announce a
  # release whose rollout actually failed.
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  export STUB_ROLLED_OUT=""
  export STUB_ROLLOUT_RETRIED="$MID_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollout failed"* ]]
  [ -z "$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)")" ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
}

@test "two dispatches in the SAME second are both announced" {
  # createdAt is second-resolution. Checkpointing on it would make a strict
  # `>` filter drop the second dispatch permanently once the first is
  # announced. The run id is monotonic and collision-free.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$MID_SHA",     "conclusion": "success", "createdAt": "2026-08-27T11:55:00Z", "status": "completed" },
  { "databaseId": 1002, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-27T11:55:00Z", "status": "completed" } ]
JSON
  _rolled_out "$MID_SHA $SHIPPED_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  tag1="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | sort | head -1)"
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag1")" = "$MID_SHA" ]
  grep -q 'last_run_id=1001' "$HYDRA_RELEASE_STATE_DIR/announced/auth"

  # The second one shares the timestamp and must still be reachable.
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  tag2="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | sort | tail -1)"
  [ "$tag2" != "$tag1" ]
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag2")" = "$SHIPPED_SHA" ]
  grep -q 'last_run_id=1002' "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "state written before run ids existed migrates without losing a release" {
  # Pre-existing state carries only last_run_at. The baseline run and the
  # unannounced one share a SECOND, so the timestamp fallback would exclude
  # the new release entirely; deriving the id from the last announced sha is
  # what keeps it reachable.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$BASE_SHA",    "conclusion": "success", "createdAt": "2026-08-27T11:55:00Z", "status": "completed" },
  { "databaseId": 1002, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-27T11:55:00Z", "status": "completed" } ]
JSON
  _rolled_out "$BASE_SHA $SHIPPED_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=v2026.8.26\nlast_run_at=2026-08-27T11:55:00Z\n' \
    "$BASE_SHA" "$BASE_SHA" > "$HYDRA_RELEASE_STATE_DIR/announced/auth"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | head -1)"
  [ -n "$tag" ]
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$SHIPPED_SHA" ]
  grep -q 'last_run_id=1002' "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "a redeploy of an announced sha advances the checkpoint, not just silence" {
  # 1001 ships A (announced); 1002 redeploys A; 1003 ships B. If the
  # duplicate tick stays silent WITHOUT advancing the checkpoint, 1002 is
  # the oldest candidate on every future tick and B is starved forever.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1002, "headSha": "$MID_SHA",     "conclusion": "success", "createdAt": "2026-08-27T12:00:00Z", "status": "completed" },
  { "databaseId": 1003, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-27T12:05:00Z", "status": "completed" } ]
JSON
  _rolled_out "$MID_SHA $SHIPPED_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  # A was already announced by run 1001. The version must be a tag that
  # actually exists in the fixture origin, or release.sh dies resolving the
  # range start and the test fails for an unrelated reason.
  _seed_state "$MID_SHA" "2026-08-27T11:55:00Z" "v2026.8.26" 1001

  # Tick 1: 1002 redeploys A -> silent, but the checkpoint must move.
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  grep -q 'last_run_id=1002' "$HYDRA_RELEASE_STATE_DIR/announced/auth"

  # Tick 2: B must now be reachable.
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | sort | tail -1)"
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$SHIPPED_SHA" ]
  grep -q "last_marker=$SHIPPED_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "a permanently statusless dispatch fails loud, it is never skipped" {
  # Every enabled repo must have a working status writer, so a dispatch that
  # never gets a record is anomalous. Skipping it could drop a real release
  # (the writer may have died after a successful rollout); waiting forever
  # would wedge the repo. Neither is acceptable silently.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$MID_SHA",     "conclusion": "success", "createdAt": "2026-08-20T10:00:00Z", "status": "completed" },
  { "databaseId": 1002, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-20T11:00:00Z", "status": "completed" } ]
JSON
  _rolled_out "$SHIPPED_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-20T09:00:00Z" "v2026.8.26" 1000

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]
  [ -z "$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)")" ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  grep -q 'last_run_id=1000' "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "repo discovery failure refuses to tag, it does not fall back to a default" {
  # The assertion guards WHICH repository receives a tag that cannot be
  # un-cut. A hardcoded fallback made it pass trivially whenever discovery
  # failed and the expected repo happened to be the default.
  export STUB_REPO_VIEW_FAIL=1
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not determine the repository"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
  [ -z "$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)")" ]
}

@test "a pending rollout that never resolves fails loud, it does not wedge" {
  # H-DevOps wrote `pending` and then died. Waiting forever would starve
  # every later release; retiring it could skip one that really shipped.
  # The state is indeterminate, so neither is acceptable silently.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$MID_SHA", "conclusion": "success", "createdAt": "2026-08-20T10:00:00Z", "status": "completed" } ]
JSON
  export STUB_ROLLED_OUT=""
  export STUB_ROLLOUT_PENDING="$MID_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-20T09:00:00Z" "v2026.8.26" 1000

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]
  [ -z "$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)")" ]
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  # And it must not silently advance past the run it could not resolve.
  grep -q 'last_run_id=1000' "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "migration picks the run the legacy timestamp named, not a later redeploy" {
  # Legacy state: run 1000 announced A. Run 1001 then ships B, and run 1002
  # redeploys A. Deriving the checkpoint from the NEWEST run for A picks
  # 1002 and drops B permanently; it must resolve the run at or before the
  # recorded last_run_at instead.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1000, "headSha": "$BASE_SHA",    "conclusion": "success", "createdAt": "2026-08-27T11:00:00Z", "status": "completed" },
  { "databaseId": 1001, "headSha": "$MID_SHA",     "conclusion": "success", "createdAt": "2026-08-27T11:30:00Z", "status": "completed" },
  { "databaseId": 1002, "headSha": "$BASE_SHA",    "conclusion": "success", "createdAt": "2026-08-27T11:45:00Z", "status": "completed" } ]
JSON
  _rolled_out "$BASE_SHA $MID_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  # Pre-run-id state, pointing at run 1000.
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=v2026.8.26\nlast_run_at=2026-08-27T11:00:00Z\n' \
    "$BASE_SHA" "$BASE_SHA" > "$HYDRA_RELEASE_STATE_DIR/announced/auth"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  # B must be the release, not skipped past.
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | head -1)"
  [ -n "$tag" ]
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$MID_SHA" ]
  grep -q "last_marker=$MID_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "a non-numeric RELEASE_STATUS_GRACE_SECONDS fails closed" {
  # Same class as RELEASE_DAILY_HOUR: bash coerces a non-numeric value toward
  # zero, which here would retire a dispatch still legitimately in flight and
  # could then announce past a release that really shipped.
  export RELEASE_STATUS_GRACE_SECONDS=abc
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-negative integer"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
}

@test "hydra picks the newest run when two share a createdAt second" {
  # jq's sort is stable and GitHub returns runs newest-first, so ordering by
  # second-resolution createdAt makes `last` select the OLDER of a tied pair
  # and the daily release tags the wrong commit. Ordering must use the
  # monotonic run id, as the status detector does.
  export STUB_REPO_NAME="Muso-AI/hydra"
  export STUB_HOUR=10
  export RELEASE_DAILY_HOUR=0
  # Newest-first, both at the same second: 1002 ships SHIPPED, 1001 ships MID.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1002, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-27T11:55:00Z", "status": "completed" },
  { "databaseId": 1001, "headSha": "$MID_SHA",     "conclusion": "success", "createdAt": "2026-08-27T11:55:00Z", "status": "completed" } ]
JSON
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  printf 'last_sha=%s\nlast_marker=%s\nlast_version=v2026.8.26\nlast_date=1970-01-01\nlast_run_at=2026-08-27T11:00:00Z\nlast_run_id=1000\n' \
    "$BASE_SHA" "$BASE_SHA" > "$HYDRA_RELEASE_STATE_DIR/announced/hydra"

  run "$SCRIPT" --repo=hydra --no-highlights
  [ "$status" -eq 0 ]
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | head -1)"
  [ -n "$tag" ]
  # The NEWER run (1002 -> SHIPPED_SHA), not the tied older one.
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$SHIPPED_SHA" ]
  grep -q "last_marker=$SHIPPED_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/hydra"
  grep -q 'last_run_id=1002' "$HYDRA_RELEASE_STATE_DIR/announced/hydra"
}

@test "unknown repo key is rejected" {
  run "$SCRIPT" --repo=not-a-repo --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown repo key"* ]]
}

# ─── Production branch is per-repo, not always `main` ────────────────────────
# release-repos.sh advertises "a new repo is one table row rather than a code
# change". That was FALSE for any repo whose prod branch is not `main`:
# release-watch.sh hardcoded `--branch main` in the status detector, the hydra
# detector, the checkout fetch and the bootstrap lookup, and release.sh gated on
# origin/main in four more places. core-backend ships from `master` (its DEFAULT
# branch is `develop`, which is dev-only), so the row alone would have produced
# a detector that silently found nothing forever -- a dead row that reads as a
# working lane. These pin the column and its wiring.

@test "every configured repo declares a production branch" {
  # A blank branch would render as `--branch ""` / `origin/` and match nothing.
  source "$HYDRA_REPO/scripts/lib/release-repos.sh"
  local k b
  for k in $(release_repo_keys); do
    b="$(release_repo_field "$k" branch)"
    [ -n "$b" ] || { echo "repo '$k' has an empty branch field" >&2; return 1; }
  done
}

@test "core-backend ships from master, never develop" {
  source "$HYDRA_REPO/scripts/lib/release-repos.sh"
  [ "$(release_repo_field core-backend branch)" = "master" ]
  # develop is core-backend's DEFAULT branch and is dev-only. Reading it as
  # shipped would announce code that never reached a customer.
  [ "$(release_repo_field core-backend branch)" != "develop" ]
}

@test "the main-shipping repos still say main (no silent retarget)" {
  source "$HYDRA_REPO/scripts/lib/release-repos.sh"
  [ "$(release_repo_field hydra branch)" = "main" ]
  [ "$(release_repo_field web-credits-next branch)" = "main" ]
}

@test "no hardcoded branch survives in the watcher" {
  run grep -nE -- '--branch main|origin main' "$HYDRA_REPO/scripts/release-watch.sh"
  [ "$status" -ne 0 ]
}

@test "both detectors resolve branch into a local before using it" {
  # An undeclared $branch under `set -u` aborts the run; without -u it would
  # expand empty and the detector would match nothing. Assert it is declared.
  run grep -c 'branch="$(release_repo_field "$key" branch)"' "$HYDRA_REPO/scripts/release-watch.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]   # status detector, hydra detector, checkout fetch
}

@test "release.sh accepts --branch and defaults it to main" {
  grep -q -- '--branch=\*) BRANCH="\${arg#--branch=}" ;;' "$HYDRA_REPO/scripts/release.sh"
  grep -q '^BRANCH="main"' "$HYDRA_REPO/scripts/release.sh"
}

@test "release.sh gates ancestry on the chosen branch, not origin/main" {
  # The ancestry gate is what stops a tag pointing at code that is not on the
  # production branch. If it still resolved origin/main it would simply fail to
  # resolve for a master-shipping repo.
  run grep -nE 'origin/main' "$HYDRA_REPO/scripts/release.sh"
  [ "$status" -ne 0 ]
}

@test "the watcher passes the repo's branch through to release.sh" {
  grep -q 'rel_args+=( --branch="$(release_repo_field "$key" branch)" )' \
    "$HYDRA_REPO/scripts/release-watch.sh"
}

@test "no enabled repo pairs cadence=daily with a busy status detector" {
  # Not a blanket ban: `daily` + `status` is fine for a repo shipping at most
  # once a day. It is unsafe for a BUSY one, because next_release_by_status
  # drains ONE candidate per tick and `daily` makes that one per DAY, so the
  # backlog grows. No enabled repo needs the pairing today; this pins that, so
  # adding one is a deliberate decision rather than an accident.
  source "$HYDRA_REPO/scripts/lib/release-repos.sh"
  local k
  for k in $(release_repo_keys --enabled-only); do
    if [ "$(release_repo_field "$k" cadence)" = "daily" ] &&
       [ "$(release_repo_field "$k" detector)" = "status" ]; then
      echo "repo '$k' pairs daily with the oldest-first status detector" >&2
      return 1
    fi
  done
}

@test "core-backend is per-deploy, the cadence its detector implements" {
  source "$HYDRA_REPO/scripts/lib/release-repos.sh"
  [ "$(release_repo_field core-backend cadence)" = "per-deploy" ]
  [ "$(release_repo_field core-backend detector)" = "status" ]
}

# ─── Standing-finding page dedupe ──────────────────────────────────────
# Two refusals in this detector are STANDING findings: they are correct,
# they are load-bearing, and they persist until a human re-seeds the
# baseline. The timer runs every 5 minutes, so failing the unit on every
# tick pages ~288 times a day for ONE finding. Measured on prod: wcn's
# 06460cdf sat `pending` for 13 days and paged on every tick (22 failures
# in 2h when Nick surfaced it).
#
# These cases pin the ONLY safe cure: the WARN record is still written
# every tick, and only the PAGE is deduped. Going quiet instead would hide
# a withheld release, which is the failure this detector exists to prevent.

# _seed_finding <fingerprint> <paged_at-epoch>
_seed_finding() {
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/findings"
  printf 'fingerprint=%s\npaged_at=%s\n' "$1" "$2" \
    > "$HYDRA_RELEASE_STATE_DIR/findings/auth"
}

# The standard "one unresolved pending rollout" fixture.
_pending_fixture() {
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$MID_SHA", "conclusion": "success", "createdAt": "2026-08-20T10:00:00Z", "status": "completed" } ]
JSON
  export STUB_ROLLED_OUT=""
  export STUB_ROLLOUT_PENDING="$MID_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-20T09:00:00Z" "v2026.8.26" 1000
}

@test "the FIRST occurrence of a standing finding pages and records a stamp" {
  _pending_fixture
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]
  # The stamp is what makes the next tick quiet; without it this is a no-op.
  grep -q "fingerprint=unresolved-rollout.*$MID_SHA.*pending" \
    "$HYDRA_RELEASE_STATE_DIR/findings/auth"
  grep -qE '^paged_at=[0-9]+$' "$HYDRA_RELEASE_STATE_DIR/findings/auth"
}

@test "an UNCHANGED standing finding is still logged but no longer pages" {
  _pending_fixture
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) - 60 ))"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]                      # no page
  [[ "$output" == *"INDETERMINATE"* ]]     # but the record is NOT suppressed
  [[ "$output" == *"not re-paged"* ]]
  # And it still refuses to announce or advance past what it cannot resolve.
  [ ! -f "$TEST_TMPDIR/posted.json" ]
  [ -z "$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)")" ]
  grep -q 'last_run_id=1000' "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "a CHANGED rollout state is a different finding and pages again" {
  # pending -> absent means the writer's behaviour changed. Inheriting the
  # old stamp's silence would swallow a genuinely new signal.
  _pending_fixture
  export STUB_ROLLOUT_PENDING=""           # now statusless, not pending
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) - 60 ))"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" != *"not re-paged"* ]]
  grep -q "none" "$HYDRA_RELEASE_STATE_DIR/findings/auth"
}

@test "a different sha is a different finding and pages again" {
  _pending_fixture
  _seed_finding "unresolved-rollout	$BASE_SHA	1001	pending" "$(( $(date -u +%s) - 60 ))"
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" != *"not re-paged"* ]]
}

@test "past the re-page window a forgotten finding resurfaces on its own" {
  # The dedupe must not become permanent amnesia.
  _pending_fixture
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) - 90000 ))"
  # The default is now "never on elapsed time alone"; the window is opt-in.
  RELEASE_FINDING_REPAGE_SECONDS=86400 run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]
}

@test "the re-page window is configurable" {
  _pending_fixture
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) - 600 ))"
  RELEASE_FINDING_REPAGE_SECONDS=300 run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]                      # 600s elapsed > 300s window
}

@test "a stamp dated in the FUTURE pages rather than staying silent forever" {
  # Clock skew must not be able to mute a finding until the clock catches
  # up: a negative elapsed reads as "inside the window" under a naive
  # upper-bound-only comparison.
  _pending_fixture
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) + 99999 ))"
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
}

@test "a CORRUPT stamp pages rather than suppressing the finding" {
  # `paged_at=not-a-number` is not merely unusable, it is FATAL without the
  # validation: bash arithmetic resolves a variable's VALUE recursively, so
  # $(( now - prev_at )) evaluates the identifier `not` and dies under
  # `set -u`. A bare `status -ne 0` assertion cannot tell that crash apart
  # from a correct page -- both are non-zero -- so pin the RECOVERY: the
  # finding is reported and the bad stamp is replaced with a valid one.
  _pending_fixture
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "not-a-number"
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]
  [[ "$output" != *"unbound variable"* ]]
  grep -qE '^paged_at=[0-9]+$' "$HYDRA_RELEASE_STATE_DIR/findings/auth"
}

@test "a TRANSIENT failure still pages on every tick — the dedupe is scoped" {
  # This is the scope guard. `could not measure` (rc 2) is self-resolving,
  # so it must keep failing every tick; only the human-gated standing
  # findings (rc 3) are deduped. A dedupe that widened to transient errors
  # would mute real breakage for a day.
  #
  # The seeded fingerprint must be the EMPTY one an rc=2 path actually
  # produces (those paths print no fingerprint). Seeding a non-matching
  # value made this test pass even with the dedupe widened to rc=2 --
  # it was green for the wrong reason, caught by mutation M5.
  _pending_fixture
  export STUB_GH_FAIL=1
  _seed_finding "" "$(( $(date -u +%s) - 60 ))"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" != *"not re-paged"* ]]
}

@test "--dry-run does not write a findings stamp" {
  # A dry run that stamped would silence the next REAL tick.
  _pending_fixture
  run "$SCRIPT" --repo=auth --no-highlights --dry-run
  [ ! -f "$HYDRA_RELEASE_STATE_DIR/findings/auth" ]
}

@test "a non-numeric RELEASE_FINDING_REPAGE_SECONDS fails closed" {
  # Same reason the grace window is validated: bash coerces a non-numeric
  # value toward zero, which would silently re-page on every tick and undo
  # the dedupe while looking configured.
  _pending_fixture
  RELEASE_FINDING_REPAGE_SECONDS=abc run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"RELEASE_FINDING_REPAGE_SECONDS must be"* ]]
}

# ─── bootstrap: "could not measure" is not "no" ─────────────────────────
# The lookup used to be `gh run list ... || echo '[]'`, so ANY gh failure
# became an empty run list and was then reported as "no successful prod
# dispatch found for <sha>" — which tells the operator to go pick a
# different sha. It cost a real investigation: core-backend's d0e4be09 was
# refused exactly that way and written off as un-bootstrappable, while run
# 35151474417 had succeeded for it the whole time.

@test "bootstrap refuses DISTINCTLY when the dispatch listing cannot be read" {
  # The message must not blame the sha, and must say retrying is the move.
  export STUB_GH_FAIL=1
  run "$SCRIPT" --repo=auth --bootstrap="$MID_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read the dispatch runs"* ]]
  [[ "$output" == *"says NOTHING about whether"* ]]
  # The misleading verdict must NOT be what an unreadable listing produces.
  [[ "$output" != *"no successful prod dispatch found"* ]]
  # And nothing may be seeded off an unmeasured read.
  [ ! -f "$HYDRA_RELEASE_STATE_DIR/announced/auth" ] \
    || ! grep -q "last_sha=$MID_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "bootstrap refuses an EMPTY dispatch listing as unmeasured, not as proof" {
  # Zero runs on a repo's production branch cannot be right, so it is a
  # failed read wearing a valid shape.
  echo '[]' > "$STUB_RUNS_JSON"
  run "$SCRIPT" --repo=auth --bootstrap="$MID_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"came back EMPTY"* ]]
  [[ "$output" == *"not as proof"* ]]
  [[ "$output" != *"no successful prod dispatch found"* ]]
}

@test "bootstrap still refuses a sha that genuinely never deployed" {
  # The scope guard: with a well-formed, non-empty listing that simply does
  # not contain the sha, the original refusal is CORRECT and must survive.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$SHIPPED_SHA", "conclusion": "success", "createdAt": "2026-08-20T10:00:00Z", "status": "completed" } ]
JSON
  run "$SCRIPT" --repo=auth --bootstrap="$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no successful prod dispatch found"* ]]
  # And it now reports how much it actually read, so the claim is checkable.
  [[ "$output" == *"runs read"* ]]
}

@test "bootstrap refuses an UNPARSEABLE dispatch listing, it does not read a baseline out of it" {
  # A zero-exit, non-array response would otherwise reach jq, fail open to
  # empty, and land on the misleading "no successful dispatch" verdict.
  export STUB_GH_RAW_STDOUT='gh: unexpected response'
  run "$SCRIPT" --repo=auth --bootstrap="$MID_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a JSON array"* ]]
  [[ "$output" != *"no successful prod dispatch found"* ]]
}

@test "a gh NOTICE on stderr does not corrupt an otherwise good listing" {
  # Regression guard for a bug introduced while fixing the fail-open: the
  # first version captured with `2>&1`, which folded gh's stderr notices
  # into the JSON and made a VALID listing fail the shape guard. stderr
  # must go to a file, never into the captured stdout.
  export STUB_GH_STDERR_NOTICE=1
  _set_runs "$MID_SHA" "2026-08-27T11:55:00Z"
  run "$SCRIPT" --repo=auth --bootstrap="$MID_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline seeded"* ]]
  [[ "$output" != *"not a JSON array"* ]]
  grep -q "last_sha=$MID_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "a REDEPLOY of the same sha after recovery pages again, it is not the old incident" {
  # QA finding on #971, and a case I had wrongly dismissed as covered.
  # Timeline: run 1001 for sha A goes indeterminate past grace and pages.
  # It later succeeds and is announced. Then run 1002 REDEPLOYS the same A
  # and goes indeterminate again, inside the 24h window. Keyed on
  # sha+state alone the fingerprint is byte-identical to the stamped
  # incident, so this brand-new deployment incident would inherit the old
  # silence and the unit would exit 0. Nothing clears the stamp on
  # recovery, so the dispatch RUN is what separates the two.
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1002, "headSha": "$MID_SHA", "conclusion": "success", "createdAt": "2026-08-20T12:00:00Z", "status": "completed" } ]
JSON
  export STUB_ROLLED_OUT=""
  export STUB_ROLLOUT_PENDING="$MID_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-20T09:00:00Z" "v2026.8.26" 1000
  # The stamp left behind by the run-1001 incident.
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) - 60 ))"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]                       # a new incident must page
  [[ "$output" == *"INDETERMINATE"* ]]
  [[ "$output" != *"not re-paged"* ]]
  # And the stamp now names the NEW run, so the next tick dedupes on it.
  grep -q "1002" "$HYDRA_RELEASE_STATE_DIR/findings/auth"
}

@test "the SAME dispatch run still dedupes across ticks" {
  # The other side of the run-id change: adding it must not defeat the
  # dedupe for the ordinary case, where one incident persists tick after
  # tick under the same run.
  _pending_fixture
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) - 60 ))"
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"not re-paged"* ]]
}

# ─── Covered-by-later-success (MUS-5149) ───────────────────────────────
# A statusless sha that is an ancestor of (or identical to) a LATER success is
# covered: that release ships its commits. Anything we cannot prove stays
# INDETERMINATE and pages (fail closed).

# _covered_fixture <second-run-sha> — run 1001 = MID (statusless), run 1002 = $1 (success)
_covered_fixture() {
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1001, "headSha": "$MID_SHA", "conclusion": "success", "createdAt": "2026-08-20T10:00:00Z", "status": "completed" },
  { "databaseId": 1002, "headSha": "$1", "conclusion": "success", "createdAt": "2026-08-20T11:00:00Z", "status": "completed" } ]
JSON
  _rolled_out "$1"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-20T09:00:00Z" "v2026.8.26" 1000
}

@test "a statusless sha that is an ANCESTOR of a later success is skipped and the later one announced" {
  _covered_fixture "$SHIPPED_SHA"
  STUB_COMPARE_STATUS=ahead run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" != *"INDETERMINATE"* ]]
  [[ "$output" == *"${MID_SHA:0:8}"* && "$output" == *"${SHIPPED_SHA:0:8}"* ]]
  [[ "$output" == *"rolled into"* ]]
  # Pin the argv: the compare must be base=skipped sha, head=later success.
  grep -q "compare/$MID_SHA...$SHIPPED_SHA" "$STUB_GH_ARGV"
  tag="$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)" | sort | tail -1)"
  [ "$(git -C "$ORIGIN" rev-list -n1 "$tag")" = "$SHIPPED_SHA" ]
  grep -q "last_marker=$SHIPPED_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  [ ! -f "$HYDRA_RELEASE_STATE_DIR/findings/auth" ]
}

@test "a sha REDEPLOYED by a later success run is never INDETERMINATE" {
  # Status is per-SHA, so run 1001 and run 1002 on one sha read the same
  # record and 1001 resolves on its own. The `identical` arm of the compare
  # is therefore only reachable on a race between the two reads; it is kept
  # because ahead alone would page on that race, but it cannot be driven
  # through this stub.
  _covered_fixture "$MID_SHA"
  STUB_COMPARE_STATUS=identical run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" != *"INDETERMINATE"* ]]
  grep -q "last_marker=$MID_SHA" "$HYDRA_RELEASE_STATE_DIR/announced/auth"
  grep -q 'last_run_id=1001' "$HYDRA_RELEASE_STATE_DIR/announced/auth"
}

@test "a statusless sha with NO later success still fails loud" {
  _pending_fixture
  export STUB_ROLLOUT_PENDING=""
  STUB_COMPARE_STATUS=ahead run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]
  # No later success to look ahead to, so no compare is even attempted.
  if grep -q "compare/" "$STUB_GH_ARGV"; then false; fi
}

@test "a later FAILED rollout does not cover a statusless sha" {
  _covered_fixture "$SHIPPED_SHA"
  export STUB_ROLLED_OUT=""; _rollout_failed "$SHIPPED_SHA"
  STUB_COMPARE_STATUS=ahead run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]
}

@test "a DIVERGED statusless sha is not covered by a later success" {
  _covered_fixture "$SHIPPED_SHA"
  STUB_COMPARE_STATUS=diverged run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]
  grep -q "compare/$MID_SHA...$SHIPPED_SHA" "$STUB_GH_ARGV"
  [ -z "$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)")" ]
}

@test "a BEHIND compare is not covered either" {
  _covered_fixture "$SHIPPED_SHA"
  STUB_COMPARE_STATUS=behind run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]
}

@test "a FAILING compare call fails closed" {
  _covered_fixture "$SHIPPED_SHA"
  run "$SCRIPT" --repo=auth --no-highlights      # STUB_COMPARE_STATUS unset -> gh exits 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]
  grep -q "compare/$MID_SHA...$SHIPPED_SHA" "$STUB_GH_ARGV"
  [ -z "$(git -C "$ORIGIN" tag -l "$(_today_tag_glob)")" ]
}

# ─── One page per new finding (MUS-5149) ───────────────────────────────

@test "by default an unchanged finding never re-pages on elapsed time alone" {
  _pending_fixture
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) - 90000 ))"
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"INDETERMINATE"* ]]      # still logged every tick
  [[ "$output" == *"not re-paged"* ]]
}

@test "a clean tick clears the stamp so the same finding pages again afterwards" {
  _pending_fixture
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) - 60 ))"
  # Recovery: the rollout lands and the tick is clean.
  _rolled_out "$MID_SHA"
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [ ! -f "$HYDRA_RELEASE_STATE_DIR/findings/auth" ]
  # The identical fingerprint recurs (same sha, run, state): it is a new page.
  _pending_fixture
  _seed_state "$BASE_SHA" "2026-08-20T09:00:00Z" "v2026.8.26" 1000
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" != *"not re-paged"* ]]
}

@test "a TRANSIENT failure does not clear the stamp" {
  _pending_fixture
  export STUB_GH_FAIL=1
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) - 60 ))"
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [ -f "$HYDRA_RELEASE_STATE_DIR/findings/auth" ]
}

@test "--dry-run does not delete a findings stamp" {
  _pending_fixture
  _seed_finding "unresolved-rollout	$MID_SHA	1001	pending" "$(( $(date -u +%s) - 60 ))"
  _rolled_out "$MID_SHA"
  run "$SCRIPT" --repo=auth --no-highlights --dry-run
  [ -f "$HYDRA_RELEASE_STATE_DIR/findings/auth" ]
}

# rc 1 ("no confirmed prod release found") is the arm that heals a stamp left
# naming a sha that is no longer a candidate -- node-8's real state after a
# re-seed. The rc 0 arm is covered above.
@test "a no-release tick (rc 1) clears a STALE stamp, and the finding pages again if it recurs" {
  cat > "$STUB_RUNS_JSON" <<JSON
[ { "databaseId": 1000, "headSha": "$BASE_SHA", "conclusion": "success", "createdAt": "2026-08-20T09:00:00Z", "status": "completed" } ]
JSON
  export STUB_ROLLED_OUT="$BASE_SHA"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-20T09:00:00Z" "v2026.8.26" 1000
  _seed_finding "unresolved-rollout	$SHIPPED_SHA	999	pending" "$(( $(date -u +%s) - 60 ))"
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"no confirmed prod release found"* ]]
  [ ! -f "$HYDRA_RELEASE_STATE_DIR/findings/auth" ]
  # The identical fingerprint recurs: a new page, not a suppressed one.
  _pending_fixture
  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -ne 0 ]
  [[ "$output" != *"not re-paged"* ]]
}


# ─── release-digest.sh: the 08:00 America/New_York roll-up ──────────────────
# NOW is fixed so the 24 h window is deterministic: 22 Oct 2026 12:00Z is
# 08:00 EDT. gh is replaced by a releases-only stub (the suite's main stub
# models sha statuses, not release listings).

DIGEST_NOW="2026-10-22T12:00:00Z"

_digest_gh_stub() {
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"
[ -n "$STUB_GH_FAIL" ] && { echo "gh: could not reach github.com" >&2; exit 1; }
filter=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && filter="$a"; prev="$a"; done
case "$2" in
  repos/*/releases*)
    f="$TEST_TMPDIR/releases-$(printf '%s' "$2" | sed 's#repos/Muso-AI/\([^/]*\)/releases.*#\1#').json"
    [ -f "$f" ] || { echo '[]' | jq -c "$filter"; exit 0; }
    # Serve ONE page, like GitHub: a stub that returned the whole fixture
    # would let a missing page loop pass. STUB_GH_IGNORE_PAGE=1 models an API
    # that ignores `page` (every request returns page 1).
    per="$(sed -n 's/.*per_page=\([0-9][0-9]*\).*/\1/p' <<<"$2")"; per="${per:-30}"
    page="$(sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p' <<<"$2")"; page="${page:-1}"
    [ -n "$STUB_GH_IGNORE_PAGE" ] && page=1
    jq -c --argjson per "$per" --argjson page "$page" ".[(\$page-1)*\$per : \$page*\$per] | $filter" "$f"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUBBIN/gh"
}

# _rel <repo-slug> <tag> <iso-published-at> <body>
_rel() {
  local f="$TEST_TMPDIR/releases-$1.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --arg t "$2" --arg p "$3" --arg b "$4" \
    '. + [{tag_name:$t, html_url:("https://github.com/x/"+$t), published_at:$p, body:$b, draft:false, prerelease:false}]' \
    "$f" > "$f.new" && mv "$f.new" "$f"
}

_digest() { DIGEST_NOW="${DIGEST_NOW_OVERRIDE:-$DIGEST_NOW}" run bash "$TEST_TMPDIR/scripts/release-digest.sh" "$@"; }
_posted_text() { jq -r '[.[] | (.text.text? // (.elements[]?.text))] | join("\n")' "$TEST_TMPDIR/posted.json"; }

@test "digest: only releases in [previous 08:00 slot, now) appear; the lower bound is inclusive" {
  _digest_gh_stub
  _rel core-backend v-in-23h  "2026-10-21T13:00:00Z" $'### Fixes\n\n- fix: in the window'
  _rel core-backend v-edge    "2026-10-21T12:00:00Z" $'### Fixes\n\n- fix: exactly 24h old'
  _rel core-backend v-old     "2026-10-21T11:59:59Z" $'### Fixes\n\n- fix: too old'
  _rel core-backend v-now     "2026-10-22T12:00:00Z" $'### Fixes\n\n- fix: published at now'
  _digest
  [ "$status" -eq 0 ]
  t="$(_posted_text)"
  [[ "$t" == *"in the window"* ]]
  [[ "$t" == *"exactly 24h old"* ]]
  [[ "$t" != *"too old"* ]]
  [[ "$t" != *"published at now"* ]]
}

@test "digest: one section per project, quiet projects omitted, bullets de-duplicated" {
  _digest_gh_stub
  _rel core-backend v1 "2026-10-22T01:00:00Z" $'### Fixes\n\n- fix: same line (#7)'
  _rel core-backend v2 "2026-10-22T02:00:00Z" $'### Fixes\n\n- fix: same line (#7)\n- fix: other line'
  _rel web-credits-next w1 "2026-10-22T03:00:00Z" $'### Features\n\n- feat: web thing'
  _digest
  [ "$status" -eq 0 ]
  t="$(_posted_text)"
  [[ "$t" == *"muso platform (backend)* — 2 releases"* ]]
  [[ "$t" == *"muso.ai web* — 1 release"* ]]
  [[ "$t" != *"hydra (agent ops)"* ]]
  [ "$(grep -c 'same line' <<<"$t")" -eq 1 ]
  [[ "$t" == *"<https://github.com/Muso-AI/core-backend/pull/7|#7>"* ]]
  grep -q 'C0TESTREL' "$STUB_MUSO_ARGV"
}

@test "digest: stored highlights replace the commit-log bullets" {
  _digest_gh_stub
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/highlights"
  _rel web-credits-next w1 "2026-10-22T03:00:00Z" $'### Features\n\n- feat: raw commit words'
  printf 'credits show up right after a claim\n' > "$HYDRA_RELEASE_STATE_DIR/highlights/web-credits-next-w1.txt"
  _digest
  t="$(_posted_text)"
  [[ "$t" == *"credits show up right after a claim"* ]]
  [[ "$t" != *"raw commit words"* ]]
}

@test "digest: an empty day posts ONE quiet line, never a crash and never silence" {
  _digest_gh_stub
  _digest
  [ "$status" -eq 0 ]
  [ -s "$TEST_TMPDIR/posted.json" ]
  [[ "$(_posted_text)" == *"No releases in the last 24 h."* ]]
  [ "$(jq '[.[] | select(.type=="section")] | length' "$TEST_TMPDIR/posted.json")" -eq 0 ]
}

@test "digest: headed with the New York date, in EDT and in EST" {
  _digest_gh_stub
  _digest
  [[ "$(jq -r '.[0].text.text' "$TEST_TMPDIR/posted.json")" == "Last 24h in production · Thu 22 Oct 2026" ]]
  # 13:00Z on 5 Nov is 08:00 EST (the clocks went back on 1 Nov): same local date.
  # Forget the 22 Oct watermark: this case is about the label, not a 14-day catch-up.
  rm -f "$HYDRA_RELEASE_STATE_DIR/digest/last-posted"
  DIGEST_NOW_OVERRIDE="2026-11-05T13:00:00Z" _digest
  [[ "$(jq -r '.[0].text.text' "$TEST_TMPDIR/posted.json")" == "Last 24h in production · Thu 5 Nov 2026" ]]
}

@test "digest: 08:00 America/New_York is 12:00Z in EDT and 13:00Z in EST" {
  run python3 - "$HYDRA_REPO/scripts/lib" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
from datetime import date
import release_blockkit as b
for d, hh in ((date(2026,10,22),12), (date(2026,11,5),13), (date(2026,3,7),13), (date(2026,3,9),12)):
    got = b.digest_slot_utc(d)
    assert got.hour == hh and got.minute == 0, (d, got)
    assert b.digest_local_date(got) == d
print("ok")
PY
  [ "$status" -eq 0 ]
}

@test "digest: fall back (25 h between fires): a release in the extra hour is still in a digest" {
  _digest_gh_stub
  # 31 Oct 08:00 EDT = 12:00Z; 1 Nov 08:00 EST = 13:00Z. now-24h would start at 31 Oct 13:00Z and drop 12:30Z.
  _rel core-backend v-extra-hour "2026-10-31T12:30:00Z" $'### Fixes\n\n- fix: published in the 25th hour'
  DIGEST_NOW_OVERRIDE="2026-11-01T13:00:00Z" _digest
  [ "$status" -eq 0 ]
  [[ "$(_posted_text)" == *"published in the 25th hour"* ]]
}

@test "digest: spring forward (23 h between fires): a release is reported once, not twice" {
  _digest_gh_stub
  # 13 Mar 08:00 EST = 13:00Z; 14 Mar 08:00 EDT = 12:00Z. now-24h would start at 13 Mar 12:00Z and repeat 12:30Z.
  _rel core-backend v-already-sent "2027-03-13T12:30:00Z" $'### Fixes\n\n- fix: already in the 13 Mar digest'
  _rel core-backend v-new "2027-03-13T13:30:00Z" $'### Fixes\n\n- fix: new since the 13 Mar digest'
  DIGEST_NOW_OVERRIDE="2027-03-14T12:00:00Z" _digest
  [ "$status" -eq 0 ]
  t="$(_posted_text)"
  [[ "$t" != *"already in the 13 Mar digest"* ]]
  [ "$(grep -c 'new since the 13 Mar digest' <<<"$t")" -eq 1 ]
}

_watermark() { mkdir -p "$HYDRA_RELEASE_STATE_DIR/digest"; printf '%s\n' "$1" > "$HYDRA_RELEASE_STATE_DIR/digest/last-posted"; }
_recorded() { cat "$HYDRA_RELEASE_STATE_DIR/digest/last-posted"; }
_count() { grep -c "$1" <<<"$(_posted_text)" || true; }

@test "digest: a catch-up run before 08:00 reports the previous slot's window and records that slot, so no release is lost" {
  _digest_gh_stub
  _watermark 2026-11-01
  _rel core-backend v-mon "2026-11-02T10:00:00Z" $'### Fixes\n\n- fix: monday thing'
  _rel core-backend v-gap "2026-11-03T12:30:00Z" $'### Fixes\n\n- fix: tuesday seven thirty'
  # Tue 3 Nov 07:00 EST: the Mon 08:00 slot is the latest one at or before now.
  DIGEST_NOW_OVERRIDE="2026-11-03T12:00:00Z" _digest
  [ "$status" -eq 0 ]
  [[ "$(_posted_text)" == *"monday thing"* ]]
  [[ "$(_posted_text)" != *"tuesday seven thirty"* ]]
  [ "$(_recorded)" = "2026-11-02" ]
  # The punctual run then reports Tue's window, which holds the 07:30 release.
  DIGEST_NOW_OVERRIDE="2026-11-03T13:05:00Z" _digest
  [ "$status" -eq 0 ]
  [ "$(_count 'tuesday seven thirty')" -eq 1 ]
  [ "$(_recorded)" = "2026-11-03" ]
}

@test "digest: a late run reports the slot's window, so a release after the slot is not counted twice" {
  _digest_gh_stub
  _watermark 2026-11-02
  _rel core-backend v-after-slot "2026-11-03T13:30:00Z" $'### Fixes\n\n- fix: after the tuesday slot'
  DIGEST_NOW_OVERRIDE="2026-11-03T14:30:00Z" _digest
  [ "$status" -eq 0 ]
  [[ "$(_posted_text)" != *"after the tuesday slot"* ]]
  DIGEST_NOW_OVERRIDE="2026-11-04T13:00:00Z" _digest
  [ "$status" -eq 0 ]
  [ "$(_count 'after the tuesday slot')" -eq 1 ]
}

@test "digest: a multi-day outage is one window from the last posted slot, across the DST change, headed honestly" {
  _digest_gh_stub
  _watermark 2026-10-30
  _rel core-backend v-oct31 "2026-10-31T10:00:00Z" $'### Fixes\n\n- fix: thing on 31 oct'
  _rel core-backend v-nov1 "2026-11-01T10:00:00Z" $'### Fixes\n\n- fix: thing on 1 nov'
  _rel core-backend v-nov2 "2026-11-02T10:00:00Z" $'### Fixes\n\n- fix: thing on 2 nov'
  _rel core-backend v-before "2026-10-30T11:59:00Z" $'### Fixes\n\n- fix: already posted on 30 oct'
  DIGEST_NOW_OVERRIDE="2026-11-03T13:00:00Z" _digest
  [ "$status" -eq 0 ]
  t="$(_posted_text)"
  for w in "thing on 31 oct" "thing on 1 nov" "thing on 2 nov"; do [ "$(grep -c "$w" <<<"$t")" -eq 1 ]; done
  [[ "$t" != *"already posted on 30 oct"* ]]
  h="$(jq -r '.[0].text.text' "$TEST_TMPDIR/posted.json")"
  [[ "$h" != *"Last 24h"* ]]
  [[ "$h" == "Releases since Fri 30 Oct 2026 · Tue 3 Nov 2026" ]]
}

@test "digest: windows are contiguous slot to slot, across both DST changes and every kind of run time" {
  run python3 - "$HYDRA_REPO/scripts/lib" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
from datetime import datetime, timedelta
import release_blockkit as b
Z = lambda t: datetime.fromisoformat(t.replace("Z", "+00:00"))
runs = ["2026-10-30T12:00:00Z", "2026-10-31T12:00:00Z",   # punctual EDT
        "2026-11-01T11:00:00Z",                           # catch-up before the slot
        "2026-11-01T13:00:00Z", "2026-11-02T14:30:00Z",   # punctual EST, then late
        "2026-11-06T13:00:00Z",                           # 3-day gap
        "2027-03-13T13:00:00Z", "2027-03-14T11:00:00Z", "2027-03-14T12:00:00Z", "2027-03-16T12:00:00Z"]
last_end = None
for r in runs:
    now = Z(r)
    start, end = b.digest_window(now, last_end)
    assert b.digest_slot_utc(b.digest_local_date(end)) == end, (r, end)   # end is a slot instant
    assert end <= now, (r, end)                                           # never reports the future
    assert start < end, (r, start, end)                                   # half-open, non-empty
    if last_end is not None and last_end < end:
        assert start == last_end, (r, start, last_end)                    # contiguous with the last post
    last_end = end if last_end is None else max(last_end, end)
for now, hrs in (("2026-11-01T13:00:00Z", 25), ("2027-03-14T12:00:00Z", 23)):
    s, e = b.digest_window(Z(now))
    assert e - s == timedelta(hours=hrs), (now, e - s)
print("ok")
PY
  [ "$status" -eq 0 ]
}

@test "digest: a corrupt last-posted warns, falls back to the previous slot, still posts, and records the slot" {
  _digest_gh_stub
  _watermark "not-a-date"
  _rel core-backend v1 "2026-10-22T01:00:00Z" $'### Fixes\n\n- fix: inside the fallback window'
  _digest
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$(_posted_text)" == *"inside the fallback window"* ]]
  [ "$(_recorded)" = "2026-10-22" ]
  # A date-shaped but impossible value is corrupt too.
  _watermark "2026-13-45"
  rm -f "$TEST_TMPDIR/posted.json"
  _digest
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [ -s "$TEST_TMPDIR/posted.json" ]
}

@test "digest: a watermark at or after the slot is already posted: exit 0, no Slack call, state untouched" {
  _digest_gh_stub
  _watermark 2026-10-23
  : > "$STUB_MUSO_ARGV"
  _digest
  [ "$status" -eq 0 ]
  [[ "$output" == *"already posted"* ]]
  [ ! -s "$STUB_MUSO_ARGV" ]
  [ "$(_recorded)" = "2026-10-23" ]
}

@test "digest: --dry-run reads the watermark for an honest preview and leaves last-posted byte-identical" {
  _digest_gh_stub
  _watermark 2026-10-20
  cp "$HYDRA_RELEASE_STATE_DIR/digest/last-posted" "$TEST_TMPDIR/lp.before"
  _rel core-backend v-old "2026-10-21T13:00:00Z" $'### Fixes\n\n- fix: two slots back'
  _digest --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"two slots back"* ]]
  [[ "$output" == *"Releases since"* ]]
  [ ! -s "$STUB_MUSO_ARGV" ]
  cmp "$HYDRA_RELEASE_STATE_DIR/digest/last-posted" "$TEST_TMPDIR/lp.before"
}

@test "digest: the timer is keyed to the IANA zone, never a fixed UTC offset" {
  # Both greps are scoped to the digest timer's own heredoc: the ClickUp digest
  # timer carries the identical OnCalendar line, so a whole-file grep is vacuous.
  # `if grep; then false; fi` because a bare `! grep` is exempt from set -e.
  local timer
  timer="$(sed -n '/^cat > .*hydra-release-digest.timer << RELDIGESTTMR$/,/^RELDIGESTTMR$/p' "$HYDRA_REPO/scripts/install-aux-units.sh")"
  [ -n "$timer" ]
  printf '%s\n' "$timer" | grep -q '^OnCalendar=\*-\*-\* 08:00:00 America/New_York$'
  if printf '%s\n' "$timer" | grep -E '^OnCalendar=.*(UTC|[+-][0-9]{2}:?[0-9]{2}|EDT|EST)'; then false; fi
  grep -q '^  hydra-release-digest.service$' "$HYDRA_REPO/scripts/install-aux-units.sh"
}

@test "digest: posts once per New York day; a re-run is a no-op" {
  _digest_gh_stub
  _digest
  [ "$status" -eq 0 ]
  : > "$STUB_MUSO_ARGV"
  _digest
  [ "$status" -eq 0 ]
  [[ "$output" == *"already posted"* ]]
  [ ! -s "$STUB_MUSO_ARGV" ]
}

@test "digest: an unreachable GitHub fails loud, posts nothing, records nothing" {
  _digest_gh_stub
  export STUB_GH_FAIL=1
  _digest
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot list releases"* ]]
  [ ! -e "$TEST_TMPDIR/posted.json" ]
  [ ! -e "$HYDRA_RELEASE_STATE_DIR/digest/last-posted" ]
}

@test "digest: a failed Slack post is not recorded, so the next run retries" {
  _digest_gh_stub
  export STUB_MUSO_FAIL=1
  _digest
  [ "$status" -ne 0 ]
  [ ! -e "$HYDRA_RELEASE_STATE_DIR/digest/last-posted" ]
}

@test "digest: --dry-run prints the payload and posts and records nothing" {
  _digest_gh_stub
  _rel core-backend v1 "2026-10-22T01:00:00Z" $'### Fixes\n\n- fix: dry thing'
  _digest --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry thing"* ]]
  [ ! -s "$STUB_MUSO_ARGV" ]
  [ ! -e "$HYDRA_RELEASE_STATE_DIR/digest/last-posted" ]
}

@test "digest: ads-manager is a table row, silent until its checkpoint is seeded; auth stays silent too" {
  . "$HYDRA_REPO/scripts/lib/release-repos.sh"
  [ "$(release_repo_field ads-manager repo)" = "Muso-AI/ads-manager" ]
  [ "$(release_repo_field ads-manager branch)" = "main" ]
  [ "$(release_repo_field ads-manager sender)" = "trigger-deploy.yaml" ]
  [ "$(release_repo_field ads-manager deploy_st)" = "H-DevOps / deploy" ]
  [ "$(release_repo_field ads-manager cadence)" = "per-deploy" ]
  [ "$(release_repo_field ads-manager enabled)" = "0" ]
  [ "$(release_repo_field auth enabled)" = "0" ]
}

@test "digest: real-size release history (>128 KB per repo) still posts: no single jq argv string over the Linux cap" {
  _digest_gh_stub
  # Linux caps ONE argv string at 128 KB (MAX_ARG_STRLEN); macOS has no cap, so
  # model it: a jq wrapper that refuses an oversize argument like node-8 does.
  local realjq; realjq="$(command -v jq)"
  cat > "$STUBBIN/jq" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\${#a}" -gt 131072 ]; then echo "jq: Argument list too long" >&2; exit 126; fi
done
exec "$realjq" "\$@"
STUB
  chmod +x "$STUBBIN/jq"
  local body; body="$(head -c 3000 /dev/zero | tr '\0' 'x')"
  local r i
  for r in hydra web-credits-next core-backend; do
    for i in $(seq 1 100); do
      _rel "$r" "v$i" "2026-10-$(printf '%02d' $((i % 20 + 1)))T12:00:00Z" "$body"
    done
    _rel "$r" "vnew" "2026-10-22T03:00:00Z" $'### Features\n\n- feat: shipped-in-'"$r"
    # GitHub lists newest first; the listing is paged now, so the order matters.
    jq '[.[-1]] + .[:-1]' "$TEST_TMPDIR/releases-$r.json" > "$TEST_TMPDIR/x.json" && mv "$TEST_TMPDIR/x.json" "$TEST_TMPDIR/releases-$r.json"
  done
  _digest
  [ "$status" -eq 0 ]
  _posted_text | grep -q "shipped-in-hydra"
  _posted_text | grep -q "shipped-in-core-backend"
}

@test "digest: a very busy day keeps the links line inside Slack's 2000-char context cap" {
  _digest_gh_stub
  local i
  for i in $(seq 1 60); do
    _rel hydra "v2026.10.22-build-number-$i" "2026-10-22T0$((i % 9)):00:00Z" $'### Features\n\n- feat: change '"$i"
  done
  _digest
  [ "$status" -eq 0 ]
  jq -e '[.[] | select(.type=="context") | .elements[].text | length] | max <= 2000' "$TEST_TMPDIR/posted.json"
  _posted_text | grep -q "more"
}

# ─── release-digest.sh: paging the release listing (MUS-17745 round 4) ──────
# One per_page=100 page reaches back only ~14 days for core-backend, so a
# catch-up window longer than that must page until it reaches the window start.

# _rels_desc <repo-slug> <count> <newest-iso> : <count> releases, one hour apart,
# newest first (the order GitHub lists them), tags r001..
_rels_desc() {
  jq -n --argjson n "$2" --arg newest "$3" \
    '[range(0; $n) | {tag_name: ("r" + (. + 1 | tostring | ("000" + .)[-3:])),
       html_url: "https://github.com/x/r", draft: false, prerelease: false,
       published_at: (($newest | fromdateiso8601) - (. * 3600) | todate),
       body: ("### Fixes\n\n- fix: change " + (. + 1 | tostring))}]' > "$TEST_TMPDIR/releases-$1.json"
}

@test "digest: a window with more than 100 releases pages on, so the oldest in-window release is reported" {
  _digest_gh_stub
  _watermark 2026-10-08
  _rels_desc core-backend 120 "2026-10-21T10:00:00Z"
  _digest
  [ "$status" -eq 0 ]
  grep -q 'page=2' "$STUB_GH_ARGV"
  [[ "$(_posted_text)" == *"muso platform (backend)* — 120 releases"* ]]
  [ "$(_recorded)" = "2026-10-22" ]
}

@test "digest: a punctual run costs exactly one releases request per enabled repo" {
  _digest_gh_stub
  # A FULL page 1 that reaches past the window start: only the min(published_at)
  # stop keeps this at one request (a short page would stop it on its own).
  _rels_desc core-backend 100 "2026-10-22T10:00:00Z"
  _digest
  [ "$status" -eq 0 ]
  # hydra, web-credits-next, core-backend, auth: the four enabled rows.
  [ "$(grep -c 'releases?' "$STUB_GH_ARGV")" -eq 4 ]
}

@test "digest: a release repeated across the page boundary is reported once" {
  _digest_gh_stub
  _watermark 2026-10-08
  _rels_desc core-backend 100 "2026-10-21T10:00:00Z"
  # A release published mid-walk pushes the boundary item onto page 2 as well.
  jq '. + [.[99]]' "$TEST_TMPDIR/releases-core-backend.json" > "$TEST_TMPDIR/x.json" && mv "$TEST_TMPDIR/x.json" "$TEST_TMPDIR/releases-core-backend.json"
  _digest
  [ "$status" -eq 0 ]
  grep -q 'page=2' "$STUB_GH_ARGV"
  [[ "$(_posted_text)" == *"muso platform (backend)* — 100 releases"* ]]
}

@test "digest: a listing that never reaches the window start dies: nothing posted, watermark untouched" {
  _digest_gh_stub
  _watermark 2026-10-08
  _rels_desc core-backend 100 "2026-10-21T10:00:00Z"
  export STUB_GH_IGNORE_PAGE=1
  DIGEST_PAGE_MAX=2 _digest
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not reach the window start in 2 pages"* ]]
  [ ! -e "$TEST_TMPDIR/posted.json" ]
  [ "$(_recorded)" = "2026-10-08" ]
}
