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
line=""; prev=""
for a in "$@"; do
  line="$line ${a//$'\n'/ }"
  # the raw --text, untouched, so tests can measure what Slack would receive
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$STUB_CALLS_DIR/text-$n.txt"
  prev="$a"
done
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
  # CURL_STUB_REPEAT_PAGE: serve ONE file for every due page (a response that never says last_page).
  */task\?*)         f="${CURL_STUB_REPEAT_PAGE:-$CURL_STUB_DIR/page${page:-0}.json}" ;;
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

# due_page <page> <last_page:true|false> <count>: a page of <count> open tasks
# spread over overdue/today/tomorrow and three statuses.
due_page() {
  jq -n --argjson p "$1" --argjson last "$2" --argjson cnt "$3" \
    --argjson o "$(due_ms 2026-06-10)" --argjson t "$(due_ms 2026-06-12)" --argjson m "$(due_ms 2026-06-13)" '
    {tasks: [range(0; $cnt) as $i | ($p * $cnt + $i) as $g
      | {id: "g\($g)", name: "Ticket \($g)", url: "https://app.clickup.com/t/g\($g)",
         due_date: (([$o + $g * 1000, $t, $m][$g % 3]) | tostring),
         status: {status: (["to do", "in progress", "waiting"][$g % 7 % 3]), type: "open"}}],
     last_page: $last}'
}

@test "31 due pages, default cap → exit 0, one parent + <=3 replies" {
  # 3100 open due tasks is the real-world shape (~2,900 on 29 Oct) that the old
  # cap of 20 pages could not finish. PAGINATION_CAP is deliberately NOT set.
  for p in $(seq 0 30); do due_page "$p" "$([ "$p" -eq 30 ] && echo true || echo false)" 100 > "$CURL_STUB_DIR/page$p.json"; done
  unset PAGINATION_CAP
  run bash "$DIGEST"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -le 4 ]
  [ "$(grep -c 'slack send' "$STUB_CALLS")" -ge 2 ]
  for f in "$STUB_CALLS_DIR"/text-*.txt; do [ "$(wc -c < "$f")" -le 3500 ]; done
  # the parent's three counts add up to every fetched task
  nums=$(grep -o '\*[0-9]*\* \(overdue\|due today\|due tomorrow\)' "$STUB_CALLS_DIR/text-1.txt" | grep -o '[0-9]*')
  [ "$(echo "$nums" | awk '{s+=$1} END{print s}')" -eq 3100 ]
}

@test "no last_page ever → exit 6 at the default cap, nothing posted" {
  due_page 0 false 5 > "$TEST_TMPDIR/forever.json"
  unset PAGINATION_CAP
  CURL_STUB_REPEAT_PAGE="$TEST_TMPDIR/forever.json" run bash "$DIGEST"
  [ "$status" -eq 6 ]
  [ "$(grep -c 'due_date_lt' "$CURL_STUB_URLS")" -eq 100 ]
  [ ! -s "$STUB_CALLS" ]
  [[ "$output" == *"PAGINATION_CAP=100"* ]]
}

@test "overdue reply: by-status counts, oldest N, per-status top 3 without duplicates, +K more, view link" {
  # 9 overdue: to do x6 (a1 a2 a4 a5 a8 a9), waiting x2 (a3 a6), in progress x1 (a7).
  # N=3 → oldest = a1 a2 a3. Per status, the 3 most overdue NOT already listed:
  # to do → a4 a5 a8 (a9 left over), waiting → a6, in progress → a7. 8 listed, K=1.
  page_with \
    "$(task a1 'Ticket a1' "$(due_ms 2026-06-01)" 'to do' open)" \
    "$(task a2 'Ticket a2' "$(due_ms 2026-06-02)" 'to do' open)" \
    "$(task a3 'Ticket a3' "$(due_ms 2026-06-03)" waiting custom)" \
    "$(task a4 'Ticket a4' "$(due_ms 2026-06-04)" 'to do' open)" \
    "$(task a5 'Ticket a5' "$(due_ms 2026-06-05)" 'to do' open)" \
    "$(task a6 'Ticket a6' "$(due_ms 2026-06-06)" waiting custom)" \
    "$(task a7 'Ticket a7' "$(due_ms 2026-06-07)" 'in progress' custom)" \
    "$(task a8 'Ticket a8' "$(due_ms 2026-06-08)" 'to do' open)" \
    "$(task a9 'Ticket a9' "$(due_ms 2026-06-09)" 'to do' open)"
  SLA_DIGEST_TOP_N=3 run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  got="$(printf '%s\n' "$output" | sed -n '/^=== THREAD/,$p' | tail -n +2)"
  view='https://app.clickup.com/2283334/v/li/901000600160'
  expected="*:rotating_light: Overdue (9):*
By status: to do 6 · waiting 2 · in progress 1
*Oldest 3:*
• <https://app.clickup.com/t/a1|Ticket a1> — [to do] — 11d overdue
• <https://app.clickup.com/t/a2|Ticket a2> — [to do] — 10d overdue
• <https://app.clickup.com/t/a3|Ticket a3> — [waiting] — 9d overdue
*Most overdue — to do:*
• <https://app.clickup.com/t/a4|Ticket a4> — [to do] — 8d overdue
• <https://app.clickup.com/t/a5|Ticket a5> — [to do] — 7d overdue
• <https://app.clickup.com/t/a8|Ticket a8> — [to do] — 4d overdue
*Most overdue — waiting:*
• <https://app.clickup.com/t/a6|Ticket a6> — [waiting] — 6d overdue
*Most overdue — in progress:*
• <https://app.clickup.com/t/a7|Ticket a7> — [in progress] — 5d overdue
+1 more overdue — <$view|open the full list>"
  [ "$got" == "$expected" ]
  # no ticket is listed twice
  [ -z "$(printf '%s\n' "$got" | grep -o 'clickup.com/t/[a-z0-9]*' | sort | uniq -d)" ]
  # the parent carries the full-list link
  printf '%s\n' "$output" | grep -qF "<$view|Full list in ClickUp>"
}

@test "status names in the By status line are escaped" {
  page_with "$(task t1 'x' "$(due_ms 2026-06-10)" 'R&D <q>' custom)"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'By status: R&amp;D &lt;q&gt; 1'
}

@test "today/tomorrow replies cap at SLA_DIGEST_TOP_N and say +K more" {
  tasks=()
  for i in 1 2 3 4 5; do tasks+=("$(task "d$i" "Today $i" "$(( $(due_ms 2026-06-12) + i * 1000 ))" 'to do' open)"); done
  tasks+=("$(task m1 'Tomorrow 1' "$(due_ms 2026-06-13)" 'to do' open)")
  page_with "${tasks[@]}"
  SLA_DIGEST_TOP_N=2 run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  today="$(printf '%s\n' "$output" | sed -n '/^=== THREAD: Due today/,/^=== THREAD: Due tomorrow/p' | sed '$d')"
  [ "$(printf '%s\n' "$today" | grep -c '^• ')" -eq 2 ]
  printf '%s\n' "$today" | grep -qF '*Due today (5):*'
  printf '%s\n' "$today" | grep -qF 'By status: to do 5'
  printf '%s\n' "$today" | grep -qF 'Today 1'
  if printf '%s\n' "$today" | grep -qF 'Today 3'; then false; fi
  printf '%s\n' "$today" | grep -qF '+3 more — <https://app.clickup.com/2283334/v/li/901000600160|open the full list>'
  # a bucket that fits has no "+K more"
  tomorrow="$(printf '%s\n' "$output" | sed -n '/^=== THREAD: Due tomorrow/,$p')"
  if printf '%s\n' "$tomorrow" | grep -q 'more'; then false; fi
}

@test "a non-integer or non-positive SLA_DIGEST_TOP_N fails loud and posts nothing" {
  for bad in ten "" 0 00 05 -1 2.5; do
    : > "$STUB_CALLS"
    page_with "$(task t1 'Overdue one' "$(due_ms 2026-06-10)" open open)"
    SLA_DIGEST_TOP_N="$bad" run bash "$DIGEST"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qF 'SLA_DIGEST_TOP_N'
    [ ! -s "$STUB_CALLS" ]
  done
}

@test "SLA_DIGEST_VIEW_URL overrides the full-list link" {
  page_with "$(task t1 'Due today' "$(due_ms 2026-06-12)" open open)"
  SLA_DIGEST_VIEW_URL='https://example.test/v' run bash "$DIGEST" --dry-run
  echo "$output" | grep -qF '<https://example.test/v|Full list in ClickUp>'
}

@test "an oversized reply is truncated, logged, never over max_chars" {
  tasks=()
  for i in $(seq 1 8); do tasks+=("$(task "o$i" "Overdue ticket number $i with a deliberately longish name" "$(( $(due_ms 2026-06-10) + i * 1000 ))" 'to do' open)"); done
  page_with "${tasks[@]}"
  LC_ALL=C SLA_DIGEST_MAX_CHARS=400 SLA_DIGEST_TOP_N=8 run bash "$DIGEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clickup-sla-digest: reply "*"Overdue (8)"*" truncated to fit"* ]]
  txt="$STUB_CALLS_DIR/text-2.txt"
  [ "$(wc -c < "$txt")" -le 400 ]
  # the footer counts the tickets that were dropped, so listed + K = 8
  listed=$(grep -c '^• ' "$txt")
  [ "$listed" -lt 8 ]
  k=$(grep -o '^+[0-9]*' "$txt" | tr -d +)
  [ "$((listed + k))" -eq 8 ]
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
