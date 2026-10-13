#!/usr/bin/env bats
# Tests for scripts/clickup-sla-digest.sh — the deterministic daily SLA
# digest posting overdue / due-today / due-tomorrow ClickUp tickets to
# #cs_chats (C0ANM0PN9L5) as a thread (glance parent + per-bucket replies),
# plus a yesterday opened/closed flow count.
#
# PATH-shadows curl (ClickUp is never touched) and muso (a real Slack send
# during a test must never page #cs_chats). Time is frozen via
# SLA_DIGEST_NOW so the today/tomorrow/yesterday boundaries are deterministic.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DIGEST="$HYDRA_REPO/scripts/clickup-sla-digest.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/pages" "$TEST_TMPDIR/counts" "$TEST_TMPDIR/calls"

  # muso stub: records each invocation. The digest now posts a thread —
  # one parent + N replies — so per-call detail matters. Each call gets a
  # flattened one-line argv dump at calls/call-<n>.line (newlines in --text
  # squashed to spaces so flags stay greppable), and every call is also
  # appended to $STUB_CALLS for quick counting. The stub returns a UNIQUE ts
  # per call (171717171<n>.000100) so a reply threading under the PARENT's ts
  # (call 1) is distinguishable from one threading under its own.
  unset MUSO_SLACK_BOT_TOKEN_OPERATIONS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  echo 'MUSO_SLACK_BOT_TOKEN_OPERATIONS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"; : > "$STUB_CALLS"
  export STUB_CALLS_DIR="$TEST_TMPDIR/calls"
  export STUB_CALL_COUNT="$TEST_TMPDIR/muso-call-count"; echo 0 > "$STUB_CALL_COUNT"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$STUB_CALL_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_CALL_COUNT"
line=""
for a in "$@"; do line="$line ${a//$'\n'/ }"; done
printf '%s\n' "$line" > "$STUB_CALLS_DIR/call-$n.line"
printf '%s\n' "$line" >> "$STUB_CALLS"
[ "${SLA_MUSO_FAIL:-0}" = "1" ] && exit 1
[ -n "${SLA_MUSO_FAIL_ON_CALL:-}" ] && [ "$n" = "$SLA_MUSO_FAIL_ON_CALL" ] && exit 1
printf '{"channel":"C0TEST","ts":"171717171%d.000100"}\n' "$n"
STUB

  # curl stub: serve fixtures keyed on the page= query param. A count-fetch
  # URL (carries date_updated_gt) is served from counts/cpage<N>.json; the due
  # fetch from pages/page<N>.json. Empty task list otherwise. Honors -o <file>
  # and -w '%{http_code}' the way the script's clickup_curl wrapper invokes curl.
  export CURL_STUB_DIR="$TEST_TMPDIR/pages"
  export COUNTS_STUB_DIR="$TEST_TMPDIR/counts"
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
# ORDER MATTERS. The task URL is `/list/<id>/task?…`, so a `*/list/[0-9]*`
# pattern matches it too — placing the metadata branch first made the stub
# answer every TASK fetch with a status document and broke 24 existing tests.
# Task requests are matched first; metadata is only what is left.
case "$url" in
  *date_updated_gt*) f="$COUNTS_STUB_DIR/cpage${page:-0}.json" ;;
  */task\?*)         f="$CURL_STUB_DIR/page${page:-0}.json" ;;
  # LIST METADATA: `/list/<id>` with no `/task`. The due fetch reads this to
  # build its open-status filter. Without this branch the request fell through
  # to the task-page fixture, `.statuses[]?` was empty, and EVERY test silently
  # took the unfiltered fallback — so the filter was never exercised at all.
  # That is the gap this closes (QA finding on PR #965).
  */list/[0-9]*)
    if [ -n "${CURL_STUB_STATUSES_FAIL:-}" ]; then
      echo '{"tasks":[]}' > "$out"      # wrong-shape metadata -> fallback path
    elif [ -f "$TEST_TMPDIR/statuses.json" ]; then
      cat "$TEST_TMPDIR/statuses.json" > "$out"
    else
      echo '{"statuses":[]}' > "$out"
    fi
    printf '200'
    exit 0
    ;;
  *)                 f="$CURL_STUB_DIR/page${page:-0}.json" ;;
esac
if [ -f "$f" ]; then cat "$f" > "$out"; else echo '{"tasks":[]}' > "$out"; fi
printf '200'
STUB
  chmod +x "$TEST_TMPDIR/bin/muso" "$TEST_TMPDIR/bin/curl"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # The real list's status set, including the SPACED names ("to do",
  # "in progress") that a `for s in $(…)` word-split would mangle, and the
  # done/closed-type ones that must never reach the filter.
  cat > "$TEST_TMPDIR/statuses.json" <<'STATUSES'
{"statuses":[
  {"status":"to do","type":"open"},
  {"status":"in progress","type":"custom"},
  {"status":"waiting","type":"custom"},
  {"status":"resolved","type":"done"},
  {"status":"impossible","type":"done"},
  {"status":"user updated","type":"closed"}
]}
STATUSES

  export CLICKUP_API_KEY=pk_test_fake
  # Freeze "now" at 2026-06-12 08:00 America/New_York (a Friday).
  # → today=2026-06-12, yesterday=2026-06-11.
  SLA_DIGEST_NOW="$(TZ=America/New_York date -d '2026-06-12 08:00' +%s)"
  export SLA_DIGEST_NOW
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# due_ms <date>: epoch ms of <date> 00:00 America/New_York (the digest
# buckets on NY date boundaries; exact within-day time must not matter).
due_ms() { echo "$(( $(TZ=America/New_York date -d "$1 00:00" +%s) * 1000 ))"; }

# ms_at <datetime>: epoch ms of an arbitrary NY datetime (for date_created /
# date_closed / date_done fixtures, which carry a time-of-day).
ms_at() { echo "$(( $(TZ=America/New_York date -d "$1" +%s) * 1000 ))"; }

# task <id> <name> <due_ms|null> <status> <status_type>
task() {
  jq -n --arg id "$1" --arg name "$2" --argjson due "$3" \
        --arg st "$4" --arg sttype "$5" \
    '{id:$id, name:$name, due_date:(if $due == null then null else ($due|tostring) end),
      url:("https://app.clickup.com/t/"+$id),
      status:{status:$st, type:$sttype}}'
}

# ctask <date_created|null> <date_closed|null> <date_done|null>: a minimal
# task carrying only the date fields the flow-count fetch reads (ms strings).
ctask() {
  jq -n --argjson c "$1" --argjson cl "$2" --argjson d "$3" \
    '{date_created:(if $c==null then null else ($c|tostring) end),
      date_closed:(if $cl==null then null else ($cl|tostring) end),
      date_done:(if $d==null then null else ($d|tostring) end)}'
}

page_with()   { jq -n --argjson tasks "$(printf '%s\n' "$@" | jq -s '.')" '{tasks:$tasks}' > "$CURL_STUB_DIR/page0.json"; }
counts_with() { jq -n --argjson tasks "$(printf '%s\n' "$@" | jq -s '.')" '{tasks:$tasks}' > "$COUNTS_STUB_DIR/cpage0.json"; }

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
  if echo "$output" | grep -q "Due next week"; then echo "due-next-week task leaked into the overdue/today/tomorrow digest" >&2; false; fi
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
  if echo "$output" | grep -q "Already resolved"; then echo "a resolved task leaked into the open-tasks digest" >&2; false; fi
  ! echo "$output" | grep -q "Marked done"
}

@test "empty buckets and no flow → no post, exit 0" {
  page_with "$(task t1 'Far future' "$(due_ms 2026-07-01)" open open)"
  # no counts fixture → 0 opened / 0 closed yesterday
  run bash "$DIGEST"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "no post"
  [ ! -s "$STUB_CALLS" ]
}

@test "posts digest to C0ANM0PN9L5 as operations bot" {
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST"
  [ "$status" -eq 0 ]
  # parent glance + 1 today reply = 2 sends
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 2 ]
  grep -q -- '--bot operations' "$STUB_CALLS"
  grep -q -- '--channel C0ANM0PN9L5' "$STUB_CALLS"
  # the today bucket detail rode in a threaded reply under the parent ts
  grep -rq 'Due today (1)' "$STUB_CALLS_DIR/"
  grep -rq -- '--thread-ts 1717171711.000100' "$STUB_CALLS_DIR/"
}

@test "posts as a thread: parent glance + one reply per bucket" {
  page_with \
    "$(task t1 'Overdue one'  "$(due_ms 2026-06-10)" open open)" \
    "$(task t2 'Due today'    "$(due_ms 2026-06-12)" open open)" \
    "$(task t3 'Due tomorrow' "$(due_ms 2026-06-13)" open open)"
  run bash "$DIGEST"
  [ "$status" -eq 0 ]
  # 1 parent + 3 bucket replies
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 4 ]
  # parent (call 1) is top-level: NO --thread-ts, carries the glance pointer
  if grep -q -- '--thread-ts' "$STUB_CALLS_DIR/call-1.line"; then echo "the parent glance message wrongly carries a --thread-ts" >&2; false; fi
  grep -q 'details in thread' "$STUB_CALLS_DIR/call-1.line"
  # replies (calls 2-4) all thread under the PARENT's returned ts (call 1's)
  grep -q -- '--thread-ts 1717171711.000100' "$STUB_CALLS_DIR/call-2.line"
  grep -q -- '--thread-ts 1717171711.000100' "$STUB_CALLS_DIR/call-3.line"
  grep -q -- '--thread-ts 1717171711.000100' "$STUB_CALLS_DIR/call-4.line"
}

@test "parent glance reports yesterday opened/closed counts (whole board)" {
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  counts_with \
    "$(ctask "$(ms_at '2026-06-11 10:00')" null null)" \
    "$(ctask "$(ms_at '2026-06-11 09:00')" "$(ms_at '2026-06-11 15:00')" null)" \
    "$(ctask "$(ms_at '2026-06-09 09:00')" null "$(ms_at '2026-06-11 16:00')")" \
    "$(ctask "$(ms_at '2026-06-12 06:00')" null null)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  # opened yesterday: rows created 6/11 = 2 (the 6/09 and 6/12 ones excluded)
  echo "$output" | grep -qF '*2* opened'
  # closed yesterday: a date_closed 6/11 + a date_done 6/11 = 2
  echo "$output" | grep -qF '*2* closed'
}

@test "count windowing survives a non-numeric date field (no blank-out)" {
  # A malformed date_created ("" instead of an ms string) must be skipped, NOT
  # abort the whole count jq and blank the glance to '** opened'. Regression
  # for the `tonumber? // -1` hardening: one valid 6/11 row still counts as 1.
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  counts_with \
    "$(ctask "$(ms_at '2026-06-11 10:00')" null null)" \
    "$(ctask '""' null null)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '*1* opened'
  ! echo "$output" | grep -qF '** opened'
}

@test "counts-only day: flow nonzero but nothing due → parent only, no replies" {
  page_with "$(task t1 'Far future' "$(due_ms 2026-07-01)" open open)"
  counts_with "$(ctask "$(ms_at '2026-06-11 10:00')" null null)"
  run bash "$DIGEST"
  [ "$status" -eq 0 ]
  # exactly the parent glance, no thread replies
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 1 ]
  if grep -q -- '--thread-ts' "$STUB_CALLS_DIR/call-1.line"; then echo "the sole parent message wrongly carries a --thread-ts" >&2; false; fi
  grep -qF '*1* opened' "$STUB_CALLS_DIR/call-1.line"
  # nothing is due, so no "details in thread" pointer
  ! grep -q 'details in thread' "$STUB_CALLS_DIR/call-1.line"
}

@test "long bucket is split into multiple in-thread replies" {
  tasks=()
  for i in $(seq 1 8); do
    tasks+=("$(task "o$i" "Overdue ticket number $i with a deliberately longish name" "$(due_ms 2026-06-10)" open open)")
  done
  page_with "${tasks[@]}"
  SLA_DIGEST_MAX_CHARS=200 run bash "$DIGEST"
  [ "$status" -eq 0 ]
  # parent + >=2 overdue replies (the bucket was split)
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -ge 3 ]
  # a continuation reply is present...
  grep -rq -- 'cont. (2/' "$STUB_CALLS_DIR/"
  # ...and every reply still threads under the parent ts (call 1's)
  grep -rq -- '--thread-ts 1717171711.000100' "$STUB_CALLS_DIR/"
}

@test "a failed thread reply → non-zero exit, parent still delivered, loud log" {
  page_with \
    "$(task t1 'Overdue one' "$(due_ms 2026-06-10)" open open)" \
    "$(task t2 'Due today'   "$(due_ms 2026-06-12)" open open)"
  # fail the first thread reply (call 2); parent (call 1) and the 2nd reply succeed
  SLA_MUSO_FAIL_ON_CALL=2 run bash "$DIGEST"
  # exit 3 specifically = degraded (a reply failed) — distinct from 1/2/5/6/7
  [ "$status" -eq 3 ]
  # parent was recorded (delivered before the failing reply)
  [ -f "$STUB_CALLS_DIR/call-1.line" ]
  if grep -q -- '--thread-ts' "$STUB_CALLS_DIR/call-1.line"; then echo "the parent message wrongly carries a --thread-ts" >&2; false; fi
  echo "$output" | grep -q "FAILED to deliver"
}

@test "--dry-run prints digest but never calls muso" {
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Due today (1)"
  echo "$output" | grep -q "=== PARENT ==="
  [ ! -s "$STUB_CALLS" ]
}

@test "ClickUp non-2xx → loud non-zero exit, no post" {
  export CURL_STUB_HTTP_CODE=403
  run bash "$DIGEST"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "HTTP 403"
  [ ! -s "$STUB_CALLS" ]
}

@test "count-fetch failure is non-fatal: due digest still posts, exit degraded" {
  # The due fetch succeeds (one ticket today); only the count fetch is broken.
  # Simulate by making the counts page an error envelope (no tasks array).
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  echo '{"err":"rate limited"}' > "$COUNTS_STUB_DIR/cpage0.json"
  run bash "$DIGEST"
  # exit 3 specifically = degraded (count-fetch failed) — the glance + reply
  # still delivered; distinct from a total-failure code
  [ "$status" -eq 3 ]
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -eq 2 ]
  grep -q 'counts unavailable' "$STUB_CALLS_DIR/call-1.line"
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
  # the DUE fetch paginated page0,1,2(empty) = 3 requests (count fetch is separate)
  [ "$(grep -c 'due_date_lt' "$CURL_STUB_URLS")" -eq 3 ]
}

@test "stops on last_page=true without an extra request" {
  jq -n --argjson t "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)" \
    '{tasks:[$t], last_page:true}' > "$CURL_STUB_DIR/page0.json"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [ "$(grep -c 'due_date_lt' "$CURL_STUB_URLS")" -eq 1 ]
}

@test "queries ClickUp with a server-side due_date_lt filter" {
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  grep -q "due_date_lt=" "$CURL_STUB_URLS"
}

@test "count fetch queries with include_closed=true and date_updated_gt" {
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  grep -q "date_updated_gt=" "$CURL_STUB_URLS"
  grep -q "include_closed=true" "$CURL_STUB_URLS"
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


# ── the open-status filter (QA finding on PR #965) ─────────────────────────
# `include_closed=false` drops only statuses of TYPE "closed"; this list also
# defines `done`-type ones (resolved, impossible) and ClickUp returns those.
# Measured: 64% of the fetched pages were tickets the jq filter discarded one
# line later, so the due fetch burned its page budget and hit PAGINATION_CAP.
# These cases pin the filter the fix added — before them, the stub served a
# task-shaped payload for the metadata URL and every test took the fallback.

# _due_url: the due-task request the script actually issued.
_due_url() { grep '/task?' "$CURL_STUB_URLS" | grep 'due_date_lt' | head -1; }

@test "the due fetch sends the list's OPEN statuses, url-encoded" {
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  url="$(_due_url)"
  [[ "$url" == *"statuses%5B%5D=to%20do"* ]]
  [[ "$url" == *"statuses%5B%5D=in%20progress"* ]]
  [[ "$url" == *"statuses%5B%5D=waiting"* ]]
}

@test "the due fetch NEVER sends done- or closed-type statuses" {
  # The whole point: resolved/impossible/user-updated are what filled the pages.
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  url="$(_due_url)"
  [[ "$url" != *"resolved"* ]]
  [[ "$url" != *"impossible"* ]]
  [[ "$url" != *"user%20updated"* ]]
}

@test "spaced status names are sent as ONE parameter each, not word-split" {
  # `for s in $(…)` splits "to do" into "to" and "do" and the filter then
  # matches nothing it was meant to. I hit exactly that while measuring the fix.
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST" --dry-run
  url="$(_due_url)"
  [ "$(printf '%s' "$url" | grep -o 'statuses%5B%5D=' | wc -l | tr -d ' ')" -eq 3 ]
  [[ "$url" != *"statuses%5B%5D=to&"* ]]
  [[ "$url" != *"statuses%5B%5D=do"* ]]
}

@test "it announces how many open statuses it filtered to" {
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST" --dry-run
  [[ "$output" == *"filtering server-side to 3 open status(es)"* ]]
}

@test "an EMPTY status list falls back to unfiltered and says so" {
  printf '%s\n' '{"statuses":[]}' > "$TEST_TMPDIR/statuses.json"
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not read open statuses"* ]]
  [[ "$output" == *"fetching unfiltered"* ]]
  [[ "$(_due_url)" != *"statuses%5B%5D"* ]]
}

@test "a metadata response of the WRONG SHAPE falls back rather than sending junk" {
  # The exact pre-fix condition: the metadata URL answered with a task page.
  run env CURL_STUB_STATUSES_FAIL=1 bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not read open statuses"* ]]
  [[ "$(_due_url)" != *"statuses%5B%5D"* ]]
}

@test "the COUNT fetch keeps include_closed=true — it measures closed flow" {
  # Scope guard: the fix must not leak onto the count fetch, which genuinely
  # needs closed tasks to report yesterday's opened/closed numbers.
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  run bash "$DIGEST" --dry-run
  count_url="$(grep 'date_updated_gt' "$CURL_STUB_URLS" | head -1)"
  [[ "$count_url" == *"include_closed=true"* ]]
  [[ "$count_url" != *"statuses%5B%5D"* ]]
}
