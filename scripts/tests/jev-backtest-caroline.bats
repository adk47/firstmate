#!/usr/bin/env bats
# Tests for scripts/jev-backtest-caroline.sh, the read-only Jev backtest for
# the Caroline pre-turn router (docs/designs/2026-09-22-jev-caroline-router.md
# section C). Hermetic: fake `curl`, `journalctl`, and `jev.sh` shadowed onto
# PATH (built in setup(), env vars exported before `run` per the
# no-env-prefix-on-run rule -- see scripts/tests/jev.bats), throwaway --out
# dir, no network, no real Intercom/Jev credentials.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/jev-backtest-caroline.sh"
FIXTURES="$HYDRA_REPO/scripts/tests/fixtures/jev-backtest"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/out" "$TEST_TMPDIR/convs"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  export MUSOAI_INTERCOM_TOKEN="test-intercom-token-do-not-print"
  export CAROLINE_BACKTEST_JEV_SH="$TEST_TMPDIR/bin/jev.sh"
  export CAROLINE_BACKTEST_TRAJECTORY_SOURCE="jsonl"
  export CAROLINE_BACKTEST_INVENTORY_FILE="$FIXTURES/caroline-inventory.json"
  export JEV_CALL_MARKER="$TEST_TMPDIR/jev-was-called"
  export BT_CONV_DIR="$TEST_TMPDIR/convs"
  export BT_SEARCH_IDS_FILE="$TEST_TMPDIR/search-ids.txt"
  : > "$BT_SEARCH_IDS_FILE"

  # Fake curl: routes POST .../conversations/search to an (empty, unless
  # BT_SEARCH_IDS_FILE names ids) search response, and GET
  # .../conversations/<id>?... to $BT_CONV_DIR/<id>.json (404 + {} when
  # absent -- mirrors a conversation the search missed). Failure seams for
  # the fail-closed search guard: BT_SEARCH_CURL_FAIL=1 (transport failure,
  # curl exits non-zero and prints no status), BT_SEARCH_HTTP_CODE (the
  # status returned for the search POST), BT_SEARCH_BODY (verbatim response
  # body, for the unparseable-shape case).
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
out="" url=""
args=("$@")
# Record every invocation's argv, and the contents of any `-H @file` header,
# so tests can assert WHERE the Intercom token travels (never argv).
printf '%s\n' "$*" >> "${BT_CURL_ARGV_LOG:-/dev/null}"
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[i]}" = "-o" ]; then out="${args[i+1]}"; fi
  if [ "${args[i]}" = "-H" ] && [[ "${args[i+1]}" == @* ]]; then
    cat "${args[i+1]#@}" >> "${BT_CURL_HDR_LOG:-/dev/null}" 2>/dev/null
  fi
done
url="${args[${#args[@]}-1]}"
if [[ "$url" == *"/conversations/search" ]]; then
  if [ "${BT_SEARCH_CURL_FAIL:-0}" = "1" ]; then
    echo "curl: (7) Failed to connect" >&2
    exit 7
  fi
  ids_json="[]"
  if [ -s "$BT_SEARCH_IDS_FILE" ]; then
    ids_json="$(jq -R -s -c 'split("\n") | map(select(length > 0)) | map({id: .})' "$BT_SEARCH_IDS_FILE")"
  fi
  body="{\"conversations\":${ids_json},\"pages\":{}}"
  if [ -n "${BT_SEARCH_BODY+x}" ]; then body="$BT_SEARCH_BODY"; fi
  if [ -n "$out" ]; then printf '%s' "$body" > "$out"; fi
  echo "${BT_SEARCH_HTTP_CODE:-200}"
  exit 0
fi
id=$(echo "$url" | sed -E 's#.*/conversations/([0-9]+).*#\1#')
src="$BT_CONV_DIR/${id}.json"
if [ ! -f "$src" ]; then
  [ -n "$out" ] && echo '{}' > "$out"
  echo "404"
  exit 0
fi
[ -n "$out" ] && cp "$src" "$out"
echo "200"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"

  # Fake journalctl: reads $CAROLINE_BACKTEST_JOURNAL_FILE instead (the
  # script's own test seam), but a stub is still needed so an accidental
  # invocation without that env var never touches the real host journal.
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"

  # Fake jev.sh: canned per-conversation answers keyed by the conv id
  # portion of --item-id ("<conv_id>-<turn>"), turn-sensitive only for the
  # troll conversation (bad-faith from turn 4 on). Touches JEV_CALL_MARKER
  # so --dry-run tests can assert it is never invoked.
  cat > "$TEST_TMPDIR/bin/jev.sh" <<STUB
#!/bin/bash
: >> "$JEV_CALL_MARKER"
item=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --item-id) item="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
conv="\${item%-*}"
turn="\${item##*-}"
case "\$conv" in
  215476013943381)
    if [ "\$turn" -ge 4 ]; then bf=0.9; else bf=0.1; fi
    echo "{\\"resolution_path\\":{\\"type\\":\\"choice\\",\\"choice\\":\\"caroline_tool\\",\\"probabilities\\":{\\"caroline_tool\\":0.5,\\"ask_customer\\":0.2,\\"human_required\\":0.1,\\"no_reply\\":0.2}},\\"intent\\":{\\"type\\":\\"choice\\",\\"choice\\":\\"other\\",\\"probabilities\\":{\\"other\\":0.9}},\\"first_tool\\":{\\"type\\":\\"choice\\",\\"choice\\":\\"none\\",\\"probabilities\\":{\\"none\\":0.9}},\\"skill\\":{\\"type\\":\\"choice\\",\\"choice\\":\\"none\\",\\"probabilities\\":{\\"none\\":0.9}},\\"off_topic_or_bad_faith\\":{\\"type\\":\\"noul\\",\\"noul\\":\$bf},\\"frustration\\":{\\"type\\":\\"score\\",\\"score\\":1,\\"legend\\":{\\"0\\":\\"Calm\\",\\"1\\":\\"Concerned\\"},\\"probabilities\\":{\\"0\\":0.3,\\"1\\":0.7}}}"
    ;;
  1001)
    echo '{"resolution_path":{"type":"choice","choice":"caroline_tool","probabilities":{"caroline_tool":0.85,"ask_customer":0.05,"human_required":0.0,"no_reply":0.1}},"intent":{"type":"choice","choice":"credit_verification","probabilities":{"credit_verification":0.88}},"first_tool":{"type":"choice","choice":"credit_verification_check","probabilities":{"credit_verification_check":0.85}},"skill":{"type":"choice","choice":"customer-credit-verification","probabilities":{"customer-credit-verification":0.8}},"off_topic_or_bad_faith":{"type":"noul","noul":0.02},"frustration":{"type":"score","score":0,"legend":{"0":"Calm"},"probabilities":{"0":0.9}}}'
    ;;
  1002)
    echo '{"resolution_path":{"type":"choice","choice":"human_required","probabilities":{"caroline_tool":0.05,"ask_customer":0.05,"human_required":0.85,"no_reply":0.05}},"intent":{"type":"choice","choice":"billing_cancel_refund","probabilities":{"billing_cancel_refund":0.8}},"first_tool":{"type":"choice","choice":"none","probabilities":{"none":0.7}},"skill":{"type":"choice","choice":"none","probabilities":{"none":0.7}},"off_topic_or_bad_faith":{"type":"noul","noul":0.05},"frustration":{"type":"score","score":2,"legend":{"2":"Frustrated"},"probabilities":{"2":0.8}}}'
    ;;
  1003)
    echo '{"resolution_path":{"type":"choice","choice":"no_reply","probabilities":{"caroline_tool":0.1,"ask_customer":0.05,"human_required":0.0,"no_reply":0.8}},"intent":{"type":"choice","choice":"profile_claim","probabilities":{"profile_claim":0.5}},"first_tool":{"type":"choice","choice":"none","probabilities":{"none":0.7}},"skill":{"type":"choice","choice":"none","probabilities":{"none":0.7}},"off_topic_or_bad_faith":{"type":"noul","noul":0.03},"frustration":{"type":"score","score":0,"legend":{"0":"Calm"},"probabilities":{"0":0.9}}}'
    ;;
  5001)
    # turn-sensitive: turn 1's long, question-bearing message is a
    # deliberate no_reply FALSE POSITIVE (high prob, fails the closer
    # guard); turn 2 ("ok") is the real closer, a true positive.
    if [ "\$turn" -eq 1 ]; then nr="0.75"; else nr="0.85"; fi
    echo "{\\"resolution_path\\":{\\"type\\":\\"choice\\",\\"choice\\":\\"no_reply\\",\\"probabilities\\":{\\"caroline_tool\\":0.05,\\"ask_customer\\":0.05,\\"human_required\\":0.0,\\"no_reply\\":\$nr}},\\"intent\\":{\\"type\\":\\"choice\\",\\"choice\\":\\"none\\",\\"probabilities\\":{\\"none\\":0.5}},\\"first_tool\\":{\\"type\\":\\"choice\\",\\"choice\\":\\"none\\",\\"probabilities\\":{\\"none\\":0.5}},\\"skill\\":{\\"type\\":\\"choice\\",\\"choice\\":\\"none\\",\\"probabilities\\":{\\"none\\":0.5}},\\"off_topic_or_bad_faith\\":{\\"type\\":\\"noul\\",\\"noul\\":0.02},\\"frustration\\":{\\"type\\":\\"score\\",\\"score\\":0,\\"legend\\":{\\"0\\":\\"Calm\\"},\\"probabilities\\":{\\"0\\":0.9}}}"
    ;;
  *)
    echo '{}'
    ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/jev.sh"

  # Common main scenario: cohort a=1001 (tool call), b=1002 (dispute),
  # c=1003 (closer), d=troll. Trajectory ts is substituted to "now" so the
  # fixture never goes stale against --days.
  export CAROLINE_BACKTEST_JOURNAL_FILE="$TEST_TMPDIR/journal-main.log"
  cp "$FIXTURES/journal-main.log" "$CAROLINE_BACKTEST_JOURNAL_FILE"
  export CAROLINE_BACKTEST_TRAJECTORY_GLOB="$TEST_TMPDIR/trajectory-main.jsonl"
  now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sed "s/__TS__/$now_ts/g" "$FIXTURES/trajectory-main.jsonl" > "$CAROLINE_BACKTEST_TRAJECTORY_GLOB"
  cp "$FIXTURES/conv-1001.json" "$BT_CONV_DIR/1001.json"
  cp "$FIXTURES/conv-1002.json" "$BT_CONV_DIR/1002.json"
  cp "$FIXTURES/conv-1003.json" "$BT_CONV_DIR/1003.json"
  cp "$FIXTURES/conv-troll.json" "$BT_CONV_DIR/215476013943381.json"
  export QUESTIONS_FILE="$FIXTURES/questions.json"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_bt_epoch_to_iso() {
  # GNU coreutils first, then BSD/macOS. Both emit the same ISO-8601 UTC.
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

@test "--dry-run: samples all four cohorts, prints the plan, never calls jev.sh or fetches transcripts" {
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"1001"*"a"*"resolution_path=caroline_tool"* ]]
  [[ "$output" == *"1002"*"b"*"resolution_path=human_required"* ]]
  [[ "$output" == *"1003"*"c"*"resolution_path=no_reply"* ]]
  [[ "$output" == *"215476013943381"*"d"*"off_topic_or_bad_faith=true from customer message 4"* ]]
  [[ "$output" == *"--dry-run, no Intercom transcript fetch or Jev call made"* ]]
  [ ! -f "$JEV_CALL_MARKER" ]
  [ ! -f "$TEST_TMPDIR/out/rows.jsonl" ]
  [ ! -f "$TEST_TMPDIR/out/report.md" ]
}

@test "cohort caps: cohort a and cohort b are each capped at 5 of 7 candidates" {
  export CAROLINE_BACKTEST_JOURNAL_FILE="$TEST_TMPDIR/journal-caps.log"
  cp "$FIXTURES/journal-caps.log" "$CAROLINE_BACKTEST_JOURNAL_FILE"
  export CAROLINE_BACKTEST_TRAJECTORY_GLOB="$TEST_TMPDIR/trajectory-caps.jsonl"
  now_epoch="$(date -u +%s)"
  tpl="$(cat "$FIXTURES/trajectory-caps.jsonl")"
  for n in 1 2 3 4 5 6 7; do
    # Epoch -> UTC differs between GNU (-d @EPOCH) and BSD/macOS (-r EPOCH):
    # `date -u -r <epoch>` reads EPOCH as a FILE on the Linux CI runner and
    # dies "No such file or directory", so probe once and use what works.
    ts="$(_bt_epoch_to_iso $((now_epoch + n * 60)))"
    tpl="${tpl//__TS${n}__/$ts}"
  done
  printf '%s\n' "$tpl" > "$CAROLINE_BACKTEST_TRAJECTORY_GLOB"

  # --limit 6 forces remaining=5, so cap_a/cap_b/cap_c all floor to 5 (the
  # "at least 5 where available" floor in the cap-computation comment) even
  # though 7 candidates exist in each of cohort a and b.
  run "$SCRIPT" --days 30 --limit 6 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE" --dry-run
  [ "$status" -eq 0 ]

  a_count=$(grep -cE '^2[0-9]{3}[[:space:]]+a[[:space:]]' <<< "$output")
  b_count=$(grep -cE '^3[0-9]{3}[[:space:]]+b[[:space:]]' <<< "$output")
  [ "$a_count" -eq 5 ]
  [ "$b_count" -eq 5 ]

  # cohort a is capped to the 5 EARLIEST tool.call events (2001-2005); the
  # two latest (2006, 2007) must be dropped.
  [[ "$output" == *"2001"* ]]
  [[ "$output" == *"2005"* ]]
  [[ "$output" != *"2006"* ]]
  [[ "$output" != *"2007"* ]]

  # cohort b is capped to the 5 lexicographically-first conv ids
  # (3001-3005); 3006/3007 must be dropped.
  [[ "$output" == *"3001"* ]]
  [[ "$output" == *"3005"* ]]
  [[ "$output" != *"3006"* ]]
  [[ "$output" != *"3007"* ]]
}

@test "cohort a label: FIRST customer turn gets resolution_path=caroline_tool, first_tool, intent from the first tool call" {
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  [ -f "$JEV_CALL_MARKER" ]

  rows="$TEST_TMPDIR/out/rows.jsonl"
  # turn 1 IS the first customer turn -- the resolving one (the request that
  # led to the tool call, not the closing "still pending though").
  jq -e '. as $r | select($r.conv_id=="1001" and $r.turn==1)
    | $r.label.resolution_path == "caroline_tool"
      and $r.label.first_tool == "credit_verification_check"
      and $r.label.intent == "credit_verification"' "$rows" >/dev/null
  # turn 2 (not the first customer turn) is replayed but left unlabeled.
  jq -e '. as $r | select($r.conv_id=="1001" and $r.turn==2)
    | $r.label.resolution_path == null and $r.label.first_tool == null and $r.label.intent == null' "$rows" >/dev/null
}

@test "cohort b label: last (only) customer turn gets resolution_path=human_required" {
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  rows="$TEST_TMPDIR/out/rows.jsonl"
  jq -e '. as $r | select($r.conv_id=="1002" and $r.turn==1)
    | $r.label.resolution_path == "human_required" and $r.label.human_required == true' "$rows" >/dev/null
}

@test "cohort c label: the closer turn gets resolution_path=no_reply, the earlier turn does not" {
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  rows="$TEST_TMPDIR/out/rows.jsonl"
  jq -e '. as $r | select($r.conv_id=="1003" and $r.turn==1)
    | $r.label.resolution_path == null and $r.label.no_reply == false' "$rows" >/dev/null
  jq -e '. as $r | select($r.conv_id=="1003" and $r.turn==2)
    | $r.label.resolution_path == "no_reply" and $r.label.no_reply == true' "$rows" >/dev/null
}

@test "cohort d label: the troll conversation is bad_faith from customer message 4 on, false before" {
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  rows="$TEST_TMPDIR/out/rows.jsonl"
  for turn in 1 2 3; do
    jq -e --argjson t "$turn" '. as $r | select($r.conv_id=="215476013943381" and $r.turn==$t) | $r.label.bad_faith == false' "$rows" >/dev/null
  done
  jq -e '. as $r | select($r.conv_id=="215476013943381" and $r.turn==4) | $r.label.bad_faith == true' "$rows" >/dev/null
}

@test "agreement math and band recommendation match the hand-computed fixture" {
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]

  # Hand-computed against the fixture's canned jev.sh answers above:
  # - resolution_path is labeled on exactly 3 rows (1001 turn1, 1002 turn1,
  #   1003 turn2), and the stub's choice matches the label on all 3 -> 100%.
  # - first_tool/intent are labeled on exactly 1 row each (1001 turn1), and
  #   the stub matches both -> 100% (the stub's answer is the same on every
  #   1001 turn, so relabeling which turn is "the" resolving one doesn't
  #   change these agreement numbers).
  # - off_topic_or_bad_faith is scored on all 9 replayed rows (2 + 1 + 2 + 4
  #   troll turns), and >=0.5 iff the label says bad_faith on every row
  #   (troll turns 1-3 stub noul=0.1 label=false, turn 4 stub noul=0.9
  #   label=true; every other row stubs noul<0.5 label=false) -> 100%.
  # - bad_faith band: fp=0 first achieved at 0.50 (troll turn4 noul=0.9 is
  #   the only positive, every negative row's noul <=0.1), recall=100%.
  # - human_required band: fp=0 first achieved at 0.50 (1002's
  #   human_required prob 0.85 is the only positive; every other row's
  #   human_required prob <=0.1), recall=100%.
  # - no_reply band: fp=0 first achieved at 0.85 (1003 turn2's no_reply prob
  #   is exactly 0.80, which does NOT clear a 0.80 threshold sweep step
  #   (0.55,0.60,...); the smallest swept threshold >0.80 is 0.85 -- so the
  #   single true positive is itself excluded there too, giving recall 0%).
  report="$TEST_TMPDIR/out/report.md"
  [ -f "$report" ]
  grep -qF "rows: 9 (malformed skipped: 0)" "$report"
  grep -qF -- "- resolution_path: 100.0% (n=3)" "$report"
  grep -qF -- "- first_tool: 100.0% (n=1)" "$report"
  grep -qF -- "- intent: 100.0% (n=1)" "$report"
  grep -qF -- "- off_topic_or_bad_faith: 100.0% (n=9)" "$report"
  grep -qF -- "- bad_faith: 0.5 (fp=0, recall=100.0%)" "$report"
  grep -qF -- "- human_required: 0.5 (fp=0, recall=100.0%)" "$report"
  grep -qF -- "- no_reply: 0.85 (fp=0, recall=0.0%)" "$report"

  # stdout mirrors the file (jev-shadow-report.sh precedent).
  [[ "$output" == *"rows: 9 (malformed skipped: 0)"* ]]

  # No cohort-b conversation in this fixture has source=user_request, so the
  # informational distribution reports zero turns.
  grep -qF -- "- n=0 (no user_request turns sampled)" "$report"
}

@test "redaction: rows.jsonl never contains the raw email, contains <email> instead" {
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  rows="$TEST_TMPDIR/out/rows.jsonl"
  [ -f "$rows" ]
  run ! grep -q "nick@example.com" "$rows"
  grep -q '<email>' "$rows"
  # every row still parses as valid, single-line JSON post-redaction.
  while IFS= read -r line; do
    echo "$line" | jq -e 'type == "object"' >/dev/null
  done < "$rows"
}

@test "first_tool filter: built-in/router-only tool calls don't qualify for cohort a; a real tool after them still does" {
  export CAROLINE_BACKTEST_JOURNAL_FILE="$TEST_TMPDIR/journal-filter.log"
  cp "$FIXTURES/journal-filter.log" "$CAROLINE_BACKTEST_JOURNAL_FILE"
  export CAROLINE_BACKTEST_TRAJECTORY_GLOB="$TEST_TMPDIR/trajectory-filter.jsonl"
  now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sed "s/__TS__/$now_ts/g" "$FIXTURES/trajectory-filter.jsonl" > "$CAROLINE_BACKTEST_TRAJECTORY_GLOB"

  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE" --dry-run
  [ "$status" -eq 0 ]

  # 4001 called only "read" then "support_action_router" -- both excluded
  # (BUILTIN_EXCLUDE) -- so it never qualifies for cohort a at all.
  [[ "$output" != *"4001"*"a"*"resolution_path=caroline_tool"* ]]
  # 4002 called the same two built-ins first, then a real support tool --
  # cohort a membership holds, and first_tool is the real tool, not a
  # built-in (the built-in calls before it are filtered out, not just
  # skipped for naming purposes).
  [[ "$output" == *"4002"*"a"*"resolution_path=caroline_tool first_tool=credit_verification_check"* ]]
}

@test "no_reply report: false-positive list and closer-guard-restricted band exclude a long, question-bearing message" {
  export CAROLINE_BACKTEST_JOURNAL_FILE="$TEST_TMPDIR/journal-closer.log"
  cp "$FIXTURES/journal-closer.log" "$CAROLINE_BACKTEST_JOURNAL_FILE"
  export CAROLINE_BACKTEST_TRAJECTORY_GLOB="$TEST_TMPDIR/trajectory-closer.jsonl"
  cp "$FIXTURES/trajectory-closer.jsonl" "$CAROLINE_BACKTEST_TRAJECTORY_GLOB"
  cp "$FIXTURES/conv-5001.json" "$BT_CONV_DIR/5001.json"

  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  report="$TEST_TMPDIR/out/report.md"
  [ -f "$report" ]

  # turn 1's long "?"-bearing message stubs no_reply=0.75 (>=0.6) despite a
  # false (unlabeled) no_reply truth -- it lands in the false-positive list;
  # turn 2 ("ok", the real closer, no_reply=0.85, label=true) does not.
  grep -qF -- "- conv=5001 turn=1: p=0.75" "$report"
  run bash -c "grep -qF -- 'conv=5001 turn=2:' '$report'"
  [ "$status" -ne 0 ]

  # Plain no_reply band is dragged to 0.8 by turn 1's false positive
  # (0.75 < 0.8 clears fp=0 there); the closer-guard-restricted band, with
  # turn 1 excluded by the guard, clears fp=0 at the very first threshold.
  grep -qF -- "- no_reply: 0.8 (fp=0, recall=100.0%)" "$report"
  grep -qF -- "- no_reply (closer-guard restricted): 0.5 (fp=0, recall=100.0%)" "$report"
}

# ── fail-closed: the Intercom conversation search ────────────
# Each of these pins one branch of _bt_intercom_search_ids. Before the fix the
# search ended in `|| return 0` and the caller in `|| : > "$search_ids_file"`,
# so every one of them produced a clean report.md from an empty/biased sample
# and exit 0 -- and those band recommendations decide what ships to customers.

@test "search 401: an expired token is a hard failure, not an empty sample" {
  export BT_SEARCH_HTTP_CODE="401"
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 4 ]
  [[ "$output" == *"credential rejected (HTTP 401"* ]]
  [ ! -f "$TEST_TMPDIR/out/report.md" ]
  [ ! -f "$TEST_TMPDIR/out/rows.jsonl" ]
  # the token itself must never reach stdout/stderr
  [[ "$output" != *"test-intercom-token-do-not-print"* ]]
}

@test "search 5xx: a server error is a hard failure, not an empty sample" {
  export BT_SEARCH_HTTP_CODE="503"
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 4 ]
  [[ "$output" == *"HTTP 503"* ]]
  [ ! -f "$TEST_TMPDIR/out/report.md" ]
  [ ! -f "$TEST_TMPDIR/out/rows.jsonl" ]
}

@test "search transport failure: curl not completing is a hard failure" {
  export BT_SEARCH_CURL_FAIL="1"
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 4 ]
  [[ "$output" == *"transport failure"* ]]
  [ ! -f "$TEST_TMPDIR/out/report.md" ]
  [ ! -f "$TEST_TMPDIR/out/rows.jsonl" ]
}

@test "search 200 with an unparseable body: a response we cannot parse is a failure, not an empty result" {
  export BT_SEARCH_BODY='<html>proxy says no</html>'
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 4 ]
  [[ "$output" == *"not the expected"* ]]
  [ ! -f "$TEST_TMPDIR/out/report.md" ]
  [ ! -f "$TEST_TMPDIR/out/rows.jsonl" ]
}

@test "search 200 with the wrong JSON shape is a failure, not an empty result" {
  # Valid JSON, HTTP 200, but no .conversations array -- e.g. an Intercom
  # error envelope. Reading zero ids out of this is indistinguishable from
  # "nothing matched" unless the shape itself is asserted.
  export BT_SEARCH_BODY='{"type":"error.list","errors":[{"code":"token_revoked"}]}'
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 4 ]
  [[ "$output" == *"not the expected"* ]]
  [ ! -f "$TEST_TMPDIR/out/report.md" ]
  [ ! -f "$TEST_TMPDIR/out/rows.jsonl" ]
}

# ── fail-closed: sample coverage ─────────────────────────────

@test "zero transcripts: every conversation GET failing refuses the report" {
  rm -f "$BT_CONV_DIR"/*.json
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 5 ]
  [[ "$output" == *"no conversation was replayed"* ]]
  [[ "$output" == *"replayed=0"* ]]
  [ ! -f "$TEST_TMPDIR/out/report.md" ]
  [ ! -f "$TEST_TMPDIR/out/rows.jsonl" ]
}

@test "partial sample: 3 of 4 sampled conversations replayed is below the 80% floor" {
  rm -f "$BT_CONV_DIR/1002.json"
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 5 ]
  [[ "$output" == *"sample coverage too low"* ]]
  [[ "$output" == *"sampled=4"* ]]
  [[ "$output" == *"replayed=3"* ]]
  [ ! -f "$TEST_TMPDIR/out/report.md" ]
  [ ! -f "$TEST_TMPDIR/out/rows.jsonl" ]
}

@test "CAROLINE_BACKTEST_MIN_FETCH_PCT lowers the coverage floor for the same partial sample" {
  rm -f "$BT_CONV_DIR/1002.json"
  export CAROLINE_BACKTEST_MIN_FETCH_PCT=50
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/out/report.md" ]
}

@test "CAROLINE_BACKTEST_MIN_FETCH_PCT is validated like the other knobs" {
  export CAROLINE_BACKTEST_MIN_FETCH_PCT="most of them"
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE" --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"CAROLINE_BACKTEST_MIN_FETCH_PCT must be an integer 1-100"* ]]

  export CAROLINE_BACKTEST_MIN_FETCH_PCT="101"
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE" --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"CAROLINE_BACKTEST_MIN_FETCH_PCT must be an integer 1-100"* ]]
}

@test "positive control: a healthy stubbed run still writes report.md and rows.jsonl" {
  # Guards that fail closed can pass every negative test by refusing
  # everything; this is the row that notices.
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/out/report.md" ]
  [ -f "$TEST_TMPDIR/out/rows.jsonl" ]
  grep -qF "rows: 9 (malformed skipped: 0)" "$TEST_TMPDIR/out/report.md"
}

@test "the Intercom token never reaches curl's argv, but still authenticates every call" {
  # argv is world-readable (/proc/<pid>/cmdline, ps) for as long as curl
  # runs. The token must travel in a header FILE instead -- and that file
  # must actually carry it, or "not in argv" would pass for a run that simply
  # stopped authenticating.
  export BT_CURL_ARGV_LOG="$TEST_TMPDIR/curl-argv.log"
  export BT_CURL_HDR_LOG="$TEST_TMPDIR/curl-hdr.log"
  : > "$BT_CURL_ARGV_LOG"; : > "$BT_CURL_HDR_LOG"
  run "$SCRIPT" --days 30 --limit 10 --out "$TEST_TMPDIR/out" --questions "$QUESTIONS_FILE"
  [ "$status" -eq 0 ]

  # Vacuity: curl was really called, or both assertions below pass trivially.
  [ -s "$BT_CURL_ARGV_LOG" ]

  # NOT `! grep ...`: bash exempts a `!`-negated command from errexit, so under
  # bats it fails the test only as the LAST line. Here it is not, and the
  # original form stayed green with the token sitting in argv (verified by
  # mutation). An explicit `if` is a real failure wherever it appears.
  if grep -qF "$MUSOAI_INTERCOM_TOKEN" "$BT_CURL_ARGV_LOG"; then
    echo "the Intercom token appeared in curl's argv" >&2
    return 1
  fi

  # Every invocation authenticated through the file.
  calls=$(grep -c . "$BT_CURL_ARGV_LOG")
  authed=$(grep -cF "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" "$BT_CURL_HDR_LOG")
  [ "$authed" -eq "$calls" ]
}
