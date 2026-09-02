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
     "$TEST_TMPDIR/scripts/"
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
  echo '[]' > "$STUB_RUNS_JSON"
  mkdir -p "$HYDRA_RELEASE_STATE_DIR/announced"
  _seed_state "$BASE_SHA" "2026-08-27T11:00:00Z" "v2026.8.26"

  run "$SCRIPT" --repo=auth --no-highlights
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_REPLY"* ]]
  [ ! -s "$STUB_RELEASE_CREATE" ]
  run git -C "$ORIGIN" tag -l
  [ -z "$output" ] || [ "$output" = "v2026.8.26" ]
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
