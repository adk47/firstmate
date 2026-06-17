#!/usr/bin/env bats
# Tests for scripts/lib/clickup-muso.sh — the USE_MUSO_CLI seam that routes the
# ClickUp cron scripts through `muso clickup raw`. Pins the translation contract
# the cutover depends on: relative-path passthrough, ?query split + url-DECODE
# (so a pre-encoded `tags%5B%5D=…` round-trips), --requester on writes, --data
# on bodies, the {data:…} envelope peel, and error propagation.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SEAM="$HYDRA_REPO/scripts/lib/clickup-muso.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/bin"
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"; : > "$STUB_CALLS"
  # muso stub: log full argv, emit a {data:…} body keyed by path; a non
  # clickup/raw call is a bad-stub error.
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
[ "${1:-}" = clickup ] && [ "${2:-}" = raw ] || { echo '{"error":{"code":"bad_stub_call"}}' >&2; exit 1; }
path="$4"
case "$path" in
  */comment) echo '{"data":{"id":"cmt1"}}' ;;
  */task)    echo '{"data":{"tasks":[{"id":"abc"}],"last_page":true}}' ;;
  /task/*)   echo '{"data":{"id":"abc","status":{"status":"resolved"}}}' ;;
  *)         echo '{"data":{}}' ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  export MUSO_BIN="$TEST_TMPDIR/bin/muso"
  # shellcheck disable=SC1090
  source "$SEAM"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "GET list: relative path + query passthrough, {data:…} peeled, no --requester on reads" {
  run clickup_muso GET "/list/901000600160/task?archived=false&page=0&order_by=due_date"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.last_page' <<<"$output")" = "true" ]
  [ "$(jq '.tasks | length' <<<"$output")" = "1" ]
  [ "$(jq 'has("data")' <<<"$output")" = "false" ]
  grep -q 'clickup raw GET /list/901000600160/task' "$STUB_CALLS"
  grep -q -- '--query archived=false' "$STUB_CALLS"
  grep -q -- '--query page=0' "$STUB_CALLS"
  grep -q -- '--query order_by=due_date' "$STUB_CALLS"
  ! grep -q -- '--requester' "$STUB_CALLS"
}

@test "pre-encoded query is url-decoded for muso (tags%5B%5D=action%3A… -> tags[]=action:…)" {
  run clickup_muso GET "/list/1/task?tags%5B%5D=action%3Aprofile-merge&include_closed=false"
  [ "$status" -eq 0 ]
  grep -qF -- '--query tags[]=action:profile-merge' "$STUB_CALLS"
  grep -q  -- '--query include_closed=false' "$STUB_CALLS"
}

@test "write (PUT) carries --requester attribution and --data body" {
  run clickup_muso PUT "/task/abc123" '{"status":"resolved"}'
  [ "$status" -eq 0 ]
  grep -q 'clickup raw PUT /task/abc123' "$STUB_CALLS"
  grep -q  -- '--requester clickup-cron@hydra-ops' "$STUB_CALLS"
  grep -qF -- '--data {"status":"resolved"}' "$STUB_CALLS"
}

@test "write (POST comment) routes through muso with --requester + body" {
  run clickup_muso POST "/task/abc/comment" '{"comment_text":"merged into 9001"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<<"$output")" = "cmt1" ]
  grep -q 'clickup raw POST /task/abc/comment' "$STUB_CALLS"
  grep -q -- '--requester clickup-cron@hydra-ops' "$STUB_CALLS"
}

@test "a muso error propagates as non-zero so the caller can fail loud" {
  cat > "$TEST_TMPDIR/bin/muso" <<'S'
#!/usr/bin/env bash
echo '{"error":{"code":"policy_refused"}}' >&2; exit 5
S
  run clickup_muso GET "/list/1/task"
  [ "$status" -eq 5 ]
}

@test "_clickup_urldecode decodes only well-formed %XX; stray % and backslashes survive" {
  [ "$(_clickup_urldecode 'tags%5B%5D')" = 'tags[]' ]        # encoded brackets
  [ "$(_clickup_urldecode 'to%20do')"   = 'to do' ]          # encoded space
  [ "$(_clickup_urldecode 'a+b')"       = 'a b' ]            # + → space
  [ "$(_clickup_urldecode '100%done')"  = '100%done' ]       # %do is not %XX → untouched, no error
  [ "$(_clickup_urldecode 'a\tb')"      = 'a\tb' ]           # literal backslash preserved, NOT a tab
  [ "$(_clickup_urldecode 'abc%')"      = 'abc%' ]           # trailing bare % → no printf error
}
