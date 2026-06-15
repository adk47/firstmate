#!/usr/bin/env bats
# Tests for scripts/clickup-sla-digest.sh — the deterministic daily SLA
# digest posting overdue / due-today / due-tomorrow ClickUp tickets to
# #cs_chats (C0ANM0PN9L5).
#
# PATH-shadows curl (ClickUp is never touched) and muso (a real Slack send
# during a test must never page #cs_chats). Time is frozen via
# SLA_DIGEST_NOW so the today/tomorrow boundaries are deterministic.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DIGEST="$HYDRA_REPO/scripts/clickup-sla-digest.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/pages"

  # muso stub: record argv, capture --text payload. The digest posts as the
  # operations ("Ops") bot, so the env file carries that token (and we unset any
  # inherited one so slack_load_env must read it from the file like production).
  unset MUSO_SLACK_BOT_TOKEN_OPERATIONS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  echo 'MUSO_SLACK_BOT_TOKEN_OPERATIONS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"
  export SLA_TEST_CAPTURE="$TEST_TMPDIR/last-text"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
[ "${SLA_MUSO_FAIL:-0}" = "1" ] && exit 1
prev=""
for a in "$@"; do
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$SLA_TEST_CAPTURE"
  prev="$a"
done
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB

  # curl stub: serve $CURL_STUB_DIR/page<N>.json keyed on the page= query
  # param; empty task list otherwise. Honors -o <file> and -w '%{http_code}'
  # the way the script's clickup_curl wrapper invokes curl.
  export CURL_STUB_DIR="$TEST_TMPDIR/pages"
  export CURL_STUB_URLS="$TEST_TMPDIR/curl-urls"
  : > "$CURL_STUB_URLS"
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
echo "$url" >> "$CURL_STUB_URLS"
if [ "${CURL_STUB_HTTP_CODE:-200}" != "200" ]; then
  echo '{"err":"oops"}' > "$out"
  printf '%s' "$CURL_STUB_HTTP_CODE"
  exit 0
fi
page=$(printf '%s' "$url" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p')
f="$CURL_STUB_DIR/page${page:-0}.json"
if [ -f "$f" ]; then cat "$f" > "$out"; else echo '{"tasks":[]}' > "$out"; fi
printf '200'
STUB
  chmod +x "$TEST_TMPDIR/bin/muso" "$TEST_TMPDIR/bin/curl"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  export CLICKUP_API_KEY=pk_test_fake
  # Freeze "now" at 2026-06-12 08:00 America/New_York (a Friday).
  SLA_DIGEST_NOW="$(TZ=America/New_York date -d '2026-06-12 08:00' +%s)"
  export SLA_DIGEST_NOW
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# due_ms <date>: epoch ms of <date> 00:00 America/New_York (the digest
# buckets on NY date boundaries; exact within-day time must not matter).
due_ms() { echo "$(( $(TZ=America/New_York date -d "$1 00:00" +%s) * 1000 ))"; }

# task <id> <name> <due_ms|null> <status> <status_type>
task() {
  jq -n --arg id "$1" --arg name "$2" --argjson due "$3" \
        --arg st "$4" --arg sttype "$5" \
    '{id:$id, name:$name, due_date:(if $due == null then null else ($due|tostring) end),
      url:("https://app.clickup.com/t/"+$id),
      status:{status:$st, type:$sttype}}'
}

page_with() { jq -n --argjson tasks "$(printf '%s\n' "$@" | jq -s '.')" '{tasks:$tasks}' > "$CURL_STUB_DIR/page0.json"; }

@test "--help exits 0 and prints usage" {
  run bash "$DIGEST" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Usage:"
  echo "$output" | grep -q -- "--dry-run"
}

@test "rejects when CLICKUP_API_KEY missing" {
  run env -u CLICKUP_API_KEY bash "$DIGEST" --dry-run
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "CLICKUP_API_KEY not set"
}

@test "rejects unknown flag" {
  run bash "$DIGEST" --frobnicate
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "unknown flag"
}

@test "buckets overdue / today / tomorrow; later and no-due excluded" {
  page_with \
    "$(task t1 'Two days overdue' "$(due_ms 2026-06-10)" open open)" \
    "$(task t2 'Due today'        "$(due_ms 2026-06-12)" open open)" \
    "$(task t3 'Due tomorrow'     "$(due_ms 2026-06-13)" open open)" \
    "$(task t4 'Due next week'    "$(due_ms 2026-06-18)" open open)" \
    "$(task t5 'No due date'      null open open)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Overdue (1)"
  echo "$output" | grep -q "Due today (1)"
  echo "$output" | grep -q "Due tomorrow (1)"
  echo "$output" | grep -q "Two days overdue"
  echo "$output" | grep -q "2d overdue"
  echo "$output" | grep -q "https://app.clickup.com/t/t1"
  ! echo "$output" | grep -q "Due next week"
  ! echo "$output" | grep -q "No due date"
}

@test "closed/done statuses excluded" {
  page_with \
    "$(task t1 'Already resolved' "$(due_ms 2026-06-10)" resolved closed)" \
    "$(task t2 'Marked done'      "$(due_ms 2026-06-10)" complete done)" \
    "$(task t3 'Still open'       "$(due_ms 2026-06-10)" 'in progress' custom)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Overdue (1)"
  echo "$output" | grep -q "Still open"
  ! echo "$output" | grep -q "Already resolved"
  ! echo "$output" | grep -q "Marked done"
}

@test "empty buckets → no post, exit 0" {
  page_with "$(task t1 'Far future' "$(due_ms 2026-07-01)" open open)"
  run bash "$DIGEST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "nothing due"
  [ ! -s "$STUB_CALLS" ]
}

@test "posts digest to C0ANM0PN9L5 as operations bot" {
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 1 ]
  grep -q -- '--bot operations' "$STUB_CALLS"
  grep -q -- '--channel C0ANM0PN9L5' "$STUB_CALLS"
  grep -q 'Due today (1)' "$SLA_TEST_CAPTURE"
}

@test "--dry-run prints digest but never calls muso" {
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Due today (1)"
  [ ! -s "$STUB_CALLS" ]
}

@test "ClickUp non-2xx → loud non-zero exit, no post" {
  export CURL_STUB_HTTP_CODE=403
  run bash "$DIGEST"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "HTTP 403"
  [ ! -s "$STUB_CALLS" ]
}

@test "failed Slack delivery → non-zero exit" {
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  SLA_MUSO_FAIL=1 run bash "$DIGEST"
  [ "$status" -ne 0 ]
}

@test "paginates and stops at the empty page" {
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  jq -n --argjson t "$(task t9 'Overdue p1' "$(due_ms 2026-06-11)" open open)" '{tasks:[$t]}' \
    > "$CURL_STUB_DIR/page1.json"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Overdue p1"
  [ "$(grep -c 'page=' "$CURL_STUB_URLS")" -eq 3 ]
}

@test "stops on last_page=true without an extra request" {
  jq -n --argjson t "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)" \
    '{tasks:[$t], last_page:true}' > "$CURL_STUB_DIR/page0.json"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [ "$(grep -c 'page=' "$CURL_STUB_URLS")" -eq 1 ]
}

@test "queries ClickUp with a server-side due_date_lt filter" {
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  grep -q "due_date_lt=" "$CURL_STUB_URLS"
}

@test "escapes Slack control chars (& < >) in ticket names" {
  page_with "$(task t1 'R&D <foo> bug' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  # entities are emitted so the title cannot break the <url|label> link
  echo "$output" | grep -q 'R&amp;D &lt;foo&gt; bug'
  # the raw control chars must not survive into the rendered line
  ! echo "$output" | grep -qF 'R&D <foo>'
}

@test "HTTP 200 with an error envelope (no tasks array) → loud exit, no post" {
  # ClickUp can answer 200 with {"err":...}; treating that as "nothing due"
  # would silently skip a day of overdue tickets, so it must fail loud.
  echo '{"err":"Team not authorized","ECODE":"OAUTH_023"}' > "$CURL_STUB_DIR/page0.json"
  run bash "$DIGEST"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no tasks array"
  [ ! -s "$STUB_CALLS" ]
}
