#!/usr/bin/env bats
# Tests for scripts/jev-eval-build.sh, the Jev eval gold-set builder.
# Hermetic: fake `curl` (routes Intercom search/get + the OpenRouter
# labeller call by URL) and a fixed `journalctl` shadowed onto PATH,
# synthetic Intercom/inventory/questions/SOUL fixtures, throwaway
# JEV_EVAL_DIR, no network, no real Intercom/OpenRouter credentials.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/jev-eval-build.sh"
FIXTURES="$HYDRA_REPO/scripts/tests/fixtures/jev-eval"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/eval" "$TEST_TMPDIR/convs"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  cp "$FIXTURES/conv-2001.json" "$TEST_TMPDIR/convs/2001.json"
  cp "$FIXTURES/conv-2002.json" "$TEST_TMPDIR/convs/2002.json"
  # 2010 is a third, single-turn conversation added specifically so the
  # split-determinism test has a conv_id whose sha256(conv_id) % 10 falls in
  # [5, 7) -- the exact boundary that distinguishes the real "< 7" tune/
  # holdout cut from a plausible off-by mutation (e.g. "< 5"); 2001/2002
  # alone both hash to 2 and can't tell the two formulas apart.
  cp "$FIXTURES/conv-2010.json" "$TEST_TMPDIR/convs/2010.json"
  printf '2001\n2002\n2010\n' > "$TEST_TMPDIR/search-ids.txt"

  export MUSOAI_INTERCOM_TOKEN="test-intercom-token-do-not-print"
  export OPENROUTER_API_KEY="test-or-key-do-not-print"
  export JEV_EVAL_DIR="$TEST_TMPDIR/eval"
  export JEV_EVAL_SOUL_FILE="$FIXTURES/soul.md"
  export JEV_EVAL_INVENTORY_FILE="$FIXTURES/caroline-inventory.json"
  export JEV_EVAL_QUESTIONS_FILE="$FIXTURES/caroline-questions.json"
  export JEV_EVAL_INTERCOM_API="https://fake-intercom.test"
  export JEV_EVAL_OPENROUTER_URL="https://fake-openrouter.test/chat"
  export CAROLINE_BOT_ADMIN_ID="bot-admin-1"
  export JEV_EVAL_JOURNAL_FILE="$TEST_TMPDIR/journal.log"
  : > "$JEV_EVAL_JOURNAL_FILE"
  export JEV_EVAL_TRAJECTORY_SOURCE="jsonl"
  export JEV_EVAL_TRAJECTORY_GLOB="$TEST_TMPDIR/no-such-trajectory-*.jsonl"

  # Fake state-cli: only --dump-closer-phrases is exercised by
  # jev-eval-build.sh (the state-builder itself is jev-eval-run.sh's
  # concern) -- returns jev-router.ts's real CLOSER_PHRASES list verbatim,
  # so build.sh's stratification is tested against the actual production
  # phrase set, not an independent fixture copy (QA re-review finding 4).
  cat > "$TEST_TMPDIR/bin/fake-state-cli.sh" <<'STUB'
#!/bin/bash
if [ "$1" = "--dump-closer-phrases" ]; then
  cat <<'JSON'
["ok","k","thanks","ty","got it","cool","great","perfect","np","no worries","sounds good","will do","👍","🙏","thank you","thanks so much"]
JSON
  exit 0
fi
echo "fake-state-cli.sh: unsupported args: $*" >&2
exit 2
STUB
  chmod +x "$TEST_TMPDIR/bin/fake-state-cli.sh"
  export JEV_EVAL_STATE_CLI_CMD="$TEST_TMPDIR/bin/fake-state-cli.sh"

  export BT_CONV_DIR="$TEST_TMPDIR/convs"
  export BT_SEARCH_IDS_FILE="$TEST_TMPDIR/search-ids.txt"
  export FAKE_LABEL_MODE="${FAKE_LABEL_MODE:-ok}"
  export FAKE_LABEL_FAIL_ON_CALL="${FAKE_LABEL_FAIL_ON_CALL:-0}"
  export FAKE_LABEL_CALL_COUNTER="$TEST_TMPDIR/label-call-count"
  : > "$FAKE_LABEL_CALL_COUNTER"

  # Fake curl: routes by URL suffix.
  #  - POST .../conversations/search -> {"conversations":[{"id":...}, ...]}
  #  - GET  .../conversations/<id>...  -> $BT_CONV_DIR/<id>.json (404 if absent)
  #  - POST $JEV_EVAL_OPENROUTER_URL   -> an OpenRouter chat-completion shape
  #    whose .choices[0].message.content is either a valid label JSON object
  #    (FAKE_LABEL_MODE=ok) or deliberately unparseable garbage
  #    (FAKE_LABEL_MODE=malformed), or valid-except-on-the-Nth-call when
  #    FAKE_LABEL_FAIL_ON_CALL=N (tests the "never drop a row" guard without
  #    making every row unlabelled).
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
out="" url=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[i]}" = "-o" ]; then out="${args[i+1]}"; fi
done
url="${args[${#args[@]}-1]}"

if [[ "$url" == *"/conversations/search" ]]; then
  ids_json="[]"
  if [ -s "$BT_SEARCH_IDS_FILE" ]; then
    ids_json="$(jq -R -s -c 'split("\n") | map(select(length > 0)) | map({id: .})' "$BT_SEARCH_IDS_FILE")"
  fi
  [ -n "$out" ] && printf '{"conversations":%s,"pages":{}}' "$ids_json" > "$out"
  echo "200"
  exit 0
fi

if [[ "$url" == "$JEV_EVAL_OPENROUTER_URL"* ]]; then
  n=$(( $(cat "$FAKE_LABEL_CALL_COUNTER" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FAKE_LABEL_CALL_COUNTER"
  mode="$FAKE_LABEL_MODE"
  if [ "${FAKE_LABEL_FAIL_ON_CALL:-0}" != "0" ] && [ "$n" = "$FAKE_LABEL_FAIL_ON_CALL" ]; then
    mode="${FAKE_LABEL_FAIL_MODE:-malformed}"
  fi
  finish_reason="stop"
  case "$mode" in
    malformed)
      content='not even close to json {{{'
      ;;
    schema_invalid)
      # Valid JSON, but "path" is not one of the five allowed values --
      # exercises validate_label's schema check, distinct from the
      # json.loads() parse-failure path above.
      content='{"path":"maybe_later","intent":"credits_missing","first_tool":"credits_lookup","needs_reply":true,"supplying_requested_info":true,"bad_faith":false,"frustration_level":0,"rationale":"test rationale"}'
      ;;
    invalid_intent)
      # Valid JSON, well-formed shape, but "intent" is not one of
      # caroline-questions.json's declared values (nor "other") --
      # exercises the intent enum check, distinct from schema_invalid's
      # "path" check above.
      content='{"path":"caroline_tool","intent":"bogus_intent_not_in_catalog","first_tool":"credits_lookup","needs_reply":true,"supplying_requested_info":true,"bad_faith":false,"frustration_level":0,"rationale":"test rationale"}'
      ;;
    invalid_first_tool)
      # Valid JSON, well-formed shape, but "first_tool" is not one of
      # caroline-inventory.json's declared tools (nor "none"/"memory_search").
      content='{"path":"caroline_tool","intent":"credits_missing","first_tool":"bogus_tool_not_in_inventory","needs_reply":true,"supplying_requested_info":true,"bad_faith":false,"frustration_level":0,"rationale":"test rationale"}'
      ;;
    no_reply_needs_reply)
      # path=no_reply but needs_reply=true -- self-contradictory per the
      # doctrine (needs_reply="a correct agent would send a message"),
      # caught upstream as a cross-field inconsistency (QA re-review
      # finding 2) before disagrees() ever sees it.
      content='{"path":"no_reply","intent":"credits_missing","first_tool":"none","needs_reply":true,"supplying_requested_info":false,"bad_faith":false,"frustration_level":0,"rationale":"test rationale"}'
      ;;
    caroline_tool_no_first_tool)
      # path=caroline_tool but first_tool=none -- schema-valid (both fields
      # are individually well-formed) but cross-field inconsistent: a
      # caroline_tool resolution always calls a real tool (QA re-review
      # finding 2).
      content='{"path":"caroline_tool","intent":"credits_missing","first_tool":"none","needs_reply":true,"supplying_requested_info":false,"bad_faith":false,"frustration_level":0,"rationale":"test rationale"}'
      ;;
    truncated)
      # A reasoning-model completion cut off mid-JSON by max_tokens -- the
      # live-observed shape: a dangling, truncated key and
      # finish_reason=length, never a clean parse failure.
      content='{"path":"caroline_tool","intent":"credits_missing","first_tool":"credits_lookup","needs_reply":true,"supplying_requested_info":true,"bad_faith":false,"frustration_level":0,"rationale":"test ratio'
      finish_reason="length"
      ;;
    *)
      content='{"path":"caroline_tool","intent":"credits_missing","first_tool":"credits_lookup","needs_reply":true,"supplying_requested_info":true,"bad_faith":false,"frustration_level":0,"rationale":"test rationale"}'
      ;;
  esac
  body=$(jq -n --arg c "$content" --arg fr "$finish_reason" '{choices:[{message:{content:$c}, finish_reason:$fr}]}')
  [ -n "$out" ] && printf '%s' "$body" > "$out"
  echo "200"
  exit 0
fi

# GET .../conversations/<id>?...
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
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "rejects a non-numeric --days" {
  run "$SCRIPT" --days abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"--days must be a positive integer"* ]]
}

@test "rejects a zero --size" {
  run "$SCRIPT" --size 0
  [ "$status" -eq 2 ]
  [[ "$output" == *"--size must be a positive integer"* ]]
}

@test "--apply-review on an unreadable file fails with exit 6" {
  run "$SCRIPT" --apply-review "$TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 6 ]
}

@test "happy path writes a gold file and review file with expected permissions" {
  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  [ -n "$gold_file" ]
  review_file=$(find "$JEV_EVAL_DIR" -name 'review-*.md')
  [ -n "$review_file" ]

  dir_perm=$(stat -c '%a' "$JEV_EVAL_DIR" 2>/dev/null || stat -f '%Lp' "$JEV_EVAL_DIR" 2>/dev/null)
  [ "$dir_perm" = "700" ]
  gold_perm=$(stat -c '%a' "$gold_file" 2>/dev/null || stat -f '%Lp' "$gold_file" 2>/dev/null)
  [ "$gold_perm" = "600" ]

  # 4 customer turns total across the two fixture conversations (2001: idx
  # 0/2/4, 2002: idx 0) and --size 10 exceeds that, so every candidate turn
  # must appear -- the sampler's top-up-from-leftover path must never
  # silently shrink the sample below what's available.
  n_rows=$(grep -c . "$gold_file")
  [ "$n_rows" -eq 5 ]
}

@test "every gold row is flagged known_facts_missing, and the summary counts it -- this harness never fabricates founding/plan/prior_chats" {
  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  n_rows=$(grep -c . "$gold_file")
  n_flagged=$(jq -s '[.[] | select(.thread_so_far.known_facts_missing == true)] | length' "$gold_file")
  [ "$n_flagged" -eq "$n_rows" ]
  [[ "$output" == *"known_facts_missing=${n_rows}"* ]]
}

@test "every gold row's split matches the deterministic sha256(conv_id) % 10 < 7 formula" {
  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  while IFS= read -r row; do
    conv_id=$(echo "$row" | jq -r '.conv_id')
    got_split=$(echo "$row" | jq -r '.split')
    want_split=$(python3 -c "
import hashlib, sys
h = int(hashlib.sha256('$conv_id'.encode()).hexdigest(), 16)
print('tune' if (h % 10) < 7 else 'holdout')
")
    [ "$got_split" = "$want_split" ]
  done < "$gold_file"
}

@test "an unparseable labeller response is counted, never dropped from the gold file" {
  FAKE_LABEL_FAIL_ON_CALL=2 run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  n_rows=$(grep -c . "$gold_file")
  [ "$n_rows" -eq 5 ]
  n_null_labels=$(jq -s '[.[] | select(.label == null)] | length' "$gold_file")
  [ "$n_null_labels" -ge 1 ]
  [[ "$output" == *"unlabelled=1"* ]] || [[ "$output" == *"unlabelled="* ]]
}

@test "a schema-invalid label (valid JSON, disallowed path value) is counted as unlabelled, never dropped" {
  FAKE_LABEL_FAIL_ON_CALL=2 FAKE_LABEL_FAIL_MODE=schema_invalid run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  n_rows=$(grep -c . "$gold_file")
  [ "$n_rows" -eq 5 ]
  n_null_labels=$(jq -s '[.[] | select(.label == null)] | length' "$gold_file")
  [ "$n_null_labels" -eq 1 ]
}

@test "an intent value outside the questions file's declared enum is counted as unlabelled, never scored as-is" {
  FAKE_LABEL_FAIL_ON_CALL=2 FAKE_LABEL_FAIL_MODE=invalid_intent run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  n_rows=$(grep -c . "$gold_file")
  [ "$n_rows" -eq 5 ]
  n_null_labels=$(jq -s '[.[] | select(.label == null)] | length' "$gold_file")
  [ "$n_null_labels" -eq 1 ]
  kind=$(jq -s -r '[.[] | select(.label == null)][0].label_error.kind' "$gold_file")
  [ "$kind" = "schema_invalid" ]
}

@test "a first_tool value outside the inventory file's declared tools is counted as unlabelled, never scored as-is" {
  FAKE_LABEL_FAIL_ON_CALL=2 FAKE_LABEL_FAIL_MODE=invalid_first_tool run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  n_rows=$(grep -c . "$gold_file")
  [ "$n_rows" -eq 5 ]
  n_null_labels=$(jq -s '[.[] | select(.label == null)] | length' "$gold_file")
  [ "$n_null_labels" -eq 1 ]
  kind=$(jq -s -r '[.[] | select(.label == null)][0].label_error.kind' "$gold_file")
  [ "$kind" = "schema_invalid" ]
}

@test "Intercom search pagination follows pages.next across multiple pages, not just the first" {
  # 4 conversations, 2 per fake search page -> real cursor-following
  # pagination (page 1 has a next cursor, page 2 does not), distinct from
  # the single-page happy path every other test exercises.
  for id in 3001 3002 3003 3004; do
    jq --arg id "$id" '.id = $id' "$FIXTURES/conv-2001.json" > "$TEST_TMPDIR/convs/${id}.json"
  done
  printf '3001\n3002\n3003\n3004\n' > "$TEST_TMPDIR/search-ids.txt"
  export BT_SEARCH_CALL_COUNTER="$TEST_TMPDIR/search-call-count"
  : > "$BT_SEARCH_CALL_COUNTER"
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
out="" url=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[i]}" = "-o" ]; then out="${args[i+1]}"; fi
done
url="${args[${#args[@]}-1]}"

if [[ "$url" == *"/conversations/search" ]]; then
  n=$(( $(cat "$BT_SEARCH_CALL_COUNTER" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$BT_SEARCH_CALL_COUNTER"
  declare -a all_ids=()
  while IFS= read -r line; do [ -n "$line" ] && all_ids+=("$line"); done < "$BT_SEARCH_IDS_FILE"
  total=${#all_ids[@]}
  start=$(( (n - 1) * 2 ))
  declare -a chunk=()
  for ((i = start; i < start + 2 && i < total; i++)); do chunk+=("${all_ids[i]}"); done
  ids_json=$(printf '%s\n' "${chunk[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0)) | map({id: .})')
  if [ $((start + 2)) -lt "$total" ]; then
    pages_json='{"next":{"starting_after":"cursor-after-page-'"$n"'"}}'
  else
    pages_json='{}'
  fi
  [ -n "$out" ] && jq -n --argjson c "$ids_json" --argjson p "$pages_json" '{conversations:$c, pages:$p}' > "$out"
  echo "200"
  exit 0
fi

if [[ "$url" == "$JEV_EVAL_OPENROUTER_URL"* ]]; then
  content='{"path":"caroline_tool","intent":"credits_missing","first_tool":"credits_lookup","needs_reply":true,"supplying_requested_info":true,"bad_faith":false,"frustration_level":0,"rationale":"test rationale"}'
  body=$(jq -n --arg c "$content" '{choices:[{message:{content:$c}, finish_reason:"stop"}]}')
  [ -n "$out" ] && printf '%s' "$body" > "$out"
  echo "200"
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

  run "$SCRIPT" --days 30 --size 20
  [ "$status" -eq 0 ]
  n_search_calls=$(cat "$BT_SEARCH_CALL_COUNTER")
  [ "$n_search_calls" -eq 2 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  got_ids=$(jq -r '.conv_id' "$gold_file" | sort -u | tr '\n' ',')
  [ "$got_ids" = "3001,3002,3003,3004," ]
  [[ "$output" == *"truncated=false"* ]]
}

@test "--max-pages caps Intercom search pagination and marks the build truncated, with a loud WARN" {
  for id in 3001 3002 3003 3004; do
    jq --arg id "$id" '.id = $id' "$FIXTURES/conv-2001.json" > "$TEST_TMPDIR/convs/${id}.json"
  done
  printf '3001\n3002\n3003\n3004\n' > "$TEST_TMPDIR/search-ids.txt"
  export BT_SEARCH_CALL_COUNTER="$TEST_TMPDIR/search-call-count"
  : > "$BT_SEARCH_CALL_COUNTER"
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
out="" url=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[i]}" = "-o" ]; then out="${args[i+1]}"; fi
done
url="${args[${#args[@]}-1]}"

if [[ "$url" == *"/conversations/search" ]]; then
  n=$(( $(cat "$BT_SEARCH_CALL_COUNTER" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$BT_SEARCH_CALL_COUNTER"
  declare -a all_ids=()
  while IFS= read -r line; do [ -n "$line" ] && all_ids+=("$line"); done < "$BT_SEARCH_IDS_FILE"
  total=${#all_ids[@]}
  start=$(( (n - 1) * 2 ))
  declare -a chunk=()
  for ((i = start; i < start + 2 && i < total; i++)); do chunk+=("${all_ids[i]}"); done
  ids_json=$(printf '%s\n' "${chunk[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0)) | map({id: .})')
  if [ $((start + 2)) -lt "$total" ]; then
    pages_json='{"next":{"starting_after":"cursor-after-page-'"$n"'"}}'
  else
    pages_json='{}'
  fi
  [ -n "$out" ] && jq -n --argjson c "$ids_json" --argjson p "$pages_json" '{conversations:$c, pages:$p}' > "$out"
  echo "200"
  exit 0
fi

if [[ "$url" == "$JEV_EVAL_OPENROUTER_URL"* ]]; then
  content='{"path":"caroline_tool","intent":"credits_missing","first_tool":"credits_lookup","needs_reply":true,"supplying_requested_info":true,"bad_faith":false,"frustration_level":0,"rationale":"test rationale"}'
  body=$(jq -n --arg c "$content" '{choices:[{message:{content:$c}, finish_reason:"stop"}]}')
  [ -n "$out" ] && printf '%s' "$body" > "$out"
  echo "200"
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

  run "$SCRIPT" --days 30 --size 20 --max-pages 1
  [ "$status" -eq 0 ]
  n_search_calls=$(cat "$BT_SEARCH_CALL_COUNTER")
  [ "$n_search_calls" -eq 1 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  got_ids=$(jq -r '.conv_id' "$gold_file" | sort -u | tr '\n' ',')
  [ "$got_ids" = "3001,3002," ]
  [[ "$output" == *"WARN Intercom conversation search hit --max-pages=1"* ]]
  [[ "$output" == *"truncated=true"* ]]
}

@test "--apply-review merges a human verdict back into its matching gold file" {
  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  review_file=$(find "$JEV_EVAL_DIR" -name 'review-*.md')

  conv_id=$(head -n1 "$gold_file" | jq -r '.conv_id')
  turn_index=$(head -n1 "$gold_file" | jq -r '.turn_index')
  human_label='{"path":"human_required","intent":"refund_request","first_tool":"none","needs_reply":true,"supplying_requested_info":false,"bad_faith":false,"frustration_level":2,"rationale":"human override"}'
  {
    echo "### conv=${conv_id} turn=${turn_index}"
    echo
    echo "verdict: ${human_label}"
    echo
  } >> "$review_file"

  run "$SCRIPT" --apply-review "$review_file"
  [ "$status" -eq 0 ]

  applied_path=$(jq -s --arg c "$conv_id" --argjson t "$turn_index" \
    '[.[] | select(.conv_id == $c and .turn_index == $t)][0].label.path' "$gold_file")
  [ "$applied_path" = '"human_required"' ]
  applied_source=$(jq -s --arg c "$conv_id" --argjson t "$turn_index" \
    '[.[] | select(.conv_id == $c and .turn_index == $t)][0].label_source' "$gold_file")
  [ "$applied_source" = '"human"' ]
}

@test "an unparseable --apply-review verdict is skipped with a warning, not applied" {
  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  review_file=$(find "$JEV_EVAL_DIR" -name 'review-*.md')
  cp "$gold_file" "$TEST_TMPDIR/gold-before.jsonl"

  conv_id=$(head -n1 "$gold_file" | jq -r '.conv_id')
  turn_index=$(head -n1 "$gold_file" | jq -r '.turn_index')
  {
    echo "### conv=${conv_id} turn=${turn_index}"
    echo
    echo "verdict: not json at all"
    echo
  } >> "$review_file"

  run "$SCRIPT" --apply-review "$review_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN unparseable verdict"* ]]
  # Compare by content, not byte-for-byte -- the merge pass re-serializes
  # every row even when a verdict is skipped, so key order can shift.
  before_norm=$(jq -S -c '.' "$TEST_TMPDIR/gold-before.jsonl" | sort)
  after_norm=$(jq -S -c '.' "$gold_file" | sort)
  [ "$before_norm" = "$after_norm" ]
}

@test "a cross-field inconsistent --apply-review human verdict is skipped with a warning, not applied (QA re-review finding 2)" {
  # Schema-valid (right types/enum values) but path=acknowledge paired with
  # needs_reply=false -- acknowledge requires needs_reply=true. A human
  # reviewer's verdict gets the SAME consistency check as the labeller's
  # own output (finding 2 names both call sites), so this can't slip a
  # self-contradictory label into the gold file just because a human typed
  # it.
  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  review_file=$(find "$JEV_EVAL_DIR" -name 'review-*.md')
  cp "$gold_file" "$TEST_TMPDIR/gold-before.jsonl"

  conv_id=$(head -n1 "$gold_file" | jq -r '.conv_id')
  turn_index=$(head -n1 "$gold_file" | jq -r '.turn_index')
  human_label='{"path":"acknowledge","intent":"credits_missing","first_tool":"none","needs_reply":false,"supplying_requested_info":false,"bad_faith":false,"frustration_level":0,"rationale":"human override"}'
  {
    echo "### conv=${conv_id} turn=${turn_index}"
    echo
    echo "verdict: ${human_label}"
    echo
  } >> "$review_file"

  run "$SCRIPT" --apply-review "$review_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN verdict"*"cross-field inconsistent"* ]]
  before_norm=$(jq -S -c '.' "$TEST_TMPDIR/gold-before.jsonl" | sort)
  after_norm=$(jq -S -c '.' "$gold_file" | sort)
  [ "$before_norm" = "$after_norm" ]
}

@test "guard: isolation holds -- the real prod eval dir is never touched" {
  # CI runs bats as root on node-8's real filesystem (docs/lessons/
  # working-in-hydra.md "ci-writes-prod": a test whose isolation seam is
  # broken doesn't fail, it silently writes production data -- that's
  # exactly how 181 fixture rows ended up in the real Jev shadow log).
  # This suite relies on JEV_EVAL_DIR pointing at $TEST_TMPDIR everywhere
  # else; this test proves that reliance actually holds by asserting the
  # real default path (/var/lib/hydra-jev/eval) gains no new files across
  # a full run, whether or not that directory happens to pre-exist on the
  # host running the suite.
  real_dir="/var/lib/hydra-jev/eval"
  marker="$TEST_TMPDIR/.guard-marker"
  : > "$marker"

  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]

  if [ -d "$real_dir" ]; then
    new_files=$(find "$real_dir" -type f -newer "$marker" 2>/dev/null || true)
    [ -z "$new_files" ]
  else
    [ ! -e "$real_dir" ]
  fi
}

@test "CAROLINE_BOT_ADMIN_ID fails closed when it cannot be resolved" {
  # An unresolved id is not a benign default -- role_of() in load_conv_parts
  # falls back to labelling EVERY admin part "admin" (not "bot"), and
  # jev-state-cli's mapAuthor DROPS "admin", so every v1 state would
  # silently contain zero Caroline turns. This must be a hard failure, not
  # a quiet fallback.
  unset CAROLINE_BOT_ADMIN_ID
  export JEV_EVAL_EDGE_CONFIG="$TEST_TMPDIR/no-such-edge-config.json"
  run "$SCRIPT" --days 30 --size 10
  [ "$status" -ne 0 ]
  [[ "$output" == *"CAROLINE_BOT_ADMIN_ID could not be resolved"* ]]
}

@test "CAROLINE_BOT_ADMIN_ID resolves from the gateway config, and Caroline vs human-admin parts are labelled correctly" {
  # Mirrors production's own resolution: config.ts reads
  # channels.intercom.accounts.<account>.botAdminId from the gateway config
  # at boot; this script must read the SAME field from the same shape of
  # file when CAROLINE_BOT_ADMIN_ID isn't set directly.
  unset CAROLINE_BOT_ADMIN_ID
  cat > "$TEST_TMPDIR/edge-config.json" <<'JSON'
{"channels":{"intercom":{"accounts":{"default":{"botAdminId":"bot-admin-1"}}}}}
JSON
  export JEV_EVAL_EDGE_CONFIG="$TEST_TMPDIR/edge-config.json"

  # A conversation with both Caroline's own reply (bot-admin-1) and a human
  # teammate's reply (a different admin id) -- isolated to this test via
  # its own search-ids.txt so it doesn't perturb the --size 10 row counts
  # the other tests assert on.
  cat > "$TEST_TMPDIR/convs/2030.json" <<'JSON'
{
  "id": "2030",
  "source": {"author": {"type": "user", "id": "u9"}, "body": "help please", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "checking now", "created_at": 110, "attachments": []},
    {"part_type": "comment", "author": {"type": "admin", "id": "human-admin-9"}, "body": "let me take over", "created_at": 120, "attachments": []},
    {"part_type": "comment", "author": {"type": "user", "id": "u9"}, "body": "thanks", "created_at": 130, "attachments": []}
  ]}
}
JSON
  printf '2030\n' > "$TEST_TMPDIR/search-ids.txt"

  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  # turn_index 3 ("thanks") is the last customer turn -- its thread_so_far
  # covers all 4 parts, so its author sequence proves both mappings at once.
  authors=$(jq -s -c '[.[] | select(.conv_id=="2030" and .turn_index==3)][0].thread_so_far.parts | map(.author)' "$gold_file")
  [ "$authors" = '["user","bot","admin","user"]' ]
}

@test "a human-admin-only reply sets human_replied but never replied (Caroline only)" {
  # Before the fix, replied_for_idx counted ANY bot-or-admin part as
  # "Caroline replied", so a pure human takeover with no Caroline
  # involvement at all still read replied=true -- which fed straight into
  # disagrees() and could hide a real no_reply miss behind a human's
  # answer. replied must be false for the human-only turn; human_replied
  # true. conv-2050 has an EARLIER Caroline (bot-admin-1) reply so the
  # pipeline's "conversations Caroline actually touched" filter keeps it;
  # the turn under test (idx 2) gets ONLY a human-admin-9 reply, no bot.
  cat > "$TEST_TMPDIR/convs/2050.json" <<'JSON'
{
  "id": "2050",
  "source": {"author": {"type": "user", "id": "u5"}, "body": "first question", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "here you go", "created_at": 110, "attachments": []},
    {"part_type": "comment", "author": {"type": "user", "id": "u5"}, "body": "need a human please", "created_at": 120, "attachments": []},
    {"part_type": "comment", "author": {"type": "admin", "id": "human-admin-9"}, "body": "I've got this", "created_at": 130, "attachments": []}
  ]}
}
JSON
  printf '2050\n' > "$TEST_TMPDIR/search-ids.txt"

  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  action=$(jq -s -c '[.[] | select(.conv_id=="2050" and .turn_index==2)][0].caroline_action' "$gold_file")
  [ "$(echo "$action" | jq -r '.replied')" = "false" ]
  [ "$(echo "$action" | jq -r '.human_replied')" = "true" ]
}

@test "an image-only opening message (empty body, real attachment) is enumerated as its own turn" {
  # Before the fix, load_conv_parts only appended the `source` part when its
  # body was non-empty -- an opening message that is a pure image (no text)
  # was dropped from `parts` entirely, so the conversation's turn_index 0
  # never existed and its stratum (image_only) could never be sampled.
  cat > "$TEST_TMPDIR/convs/2070.json" <<'JSON'
{
  "id": "2070",
  "source": {"author": {"type": "user", "id": "u7"}, "body": "", "created_at": 100, "attachments": [{"type": "image", "url": "https://example.com/shot.png"}]},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "got your screenshot, one sec", "created_at": 110, "attachments": []}
  ]}
}
JSON
  printf '2070\n' > "$TEST_TMPDIR/search-ids.txt"

  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  stratum=$(jq -s -r '[.[] | select(.conv_id=="2070" and .turn_index==0)][0].stratum' "$gold_file")
  [ "$stratum" = "image_only" ]
}

@test "a user_request escalation is not dropped, and a ticket with no journal ESCALATED line still marks the escalated turn" {
  # Two conversations: 2080 escalates via source=user_request (the customer
  # asked for a human) -- content_escs used to require source=rule, so this
  # was silently dropped from the escalated stratum. 2081 has an intercom
  # ticket (a TICKET_RE line) but no ESCALATED line at all for that conv --
  # before the fix, conv_has_ticket was never consulted as a fallback, so a
  # ticket-only conversation's turn was never marked escalated.
  cat > "$TEST_TMPDIR/convs/2080.json" <<'JSON'
{
  "id": "2080",
  "source": {"author": {"type": "user", "id": "u8"}, "body": "let me talk to a person", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "sure, one moment", "created_at": 110, "attachments": []}
  ]}
}
JSON
  cat > "$TEST_TMPDIR/convs/2081.json" <<'JSON'
{
  "id": "2081",
  "source": {"author": {"type": "user", "id": "u81"}, "body": "opening a ticket for this", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "sure, one moment", "created_at": 110, "attachments": []}
  ]}
}
JSON
  printf '2080\n2081\n' > "$TEST_TMPDIR/search-ids.txt"
  cat > "$JEV_EVAL_JOURNAL_FILE" <<'LOG'
100.0 ESCALATED conv=2080 source=user_request reason=customer asked for a human
100.0 [intercom:escalation] ticket created conv=2081 id=TICKET-1
LOG

  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  escalated_2080=$(jq -s -r '[.[] | select(.conv_id=="2080" and .turn_index==0)][0].caroline_action.escalated' "$gold_file")
  escalated_2081=$(jq -s -r '[.[] | select(.conv_id=="2081" and .turn_index==0)][0].caroline_action.escalated' "$gold_file")
  [ "$escalated_2080" = "true" ]
  [ "$escalated_2081" = "true" ]
}

@test "each tool event maps to the customer turn it follows, not always the conversation's first tool event" {
  # conv-2060 has two customer turns; a tool call happens after EACH one.
  # Before the fix, only the conversation's very FIRST tool event was ever
  # mapped to a turn (always the same event, always the same first_tool
  # value for whichever single turn landed in tool_turn_indices) -- so
  # turn_index 2's own tool call (tool_b) was invisible, and turn_index 2
  # never even got the "tool" stratum.
  cat > "$TEST_TMPDIR/convs/2060.json" <<'JSON'
{
  "id": "2060",
  "source": {"author": {"type": "user", "id": "u6"}, "body": "need help with tool A", "created_at": 1700000000, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "on it", "created_at": 1700000005, "attachments": []},
    {"part_type": "comment", "author": {"type": "user", "id": "u6"}, "body": "now I need help with tool B", "created_at": 1700000010, "attachments": []},
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "on that too", "created_at": 1700000015, "attachments": []}
  ]}
}
JSON
  printf '2060\n' > "$TEST_TMPDIR/search-ids.txt"

  export JEV_EVAL_TRAJECTORY_GLOB="$TEST_TMPDIR/trajectory.jsonl"
  cat > "$TEST_TMPDIR/trajectory.jsonl" <<'JSON'
{"type":"tool.call","data":{"name":"tool_a"},"sessionKey":"agent:support:intercom:direct:2060","ts":"2023-11-14T22:13:22Z"}
{"type":"tool.call","data":{"name":"tool_b"},"sessionKey":"agent:support:intercom:direct:2060","ts":"2023-11-14T22:13:32Z"}
JSON

  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  first_tool_0=$(jq -s -r '[.[] | select(.conv_id=="2060" and .turn_index==0)][0].caroline_action.first_tool' "$gold_file")
  first_tool_2=$(jq -s -r '[.[] | select(.conv_id=="2060" and .turn_index==2)][0].caroline_action.first_tool' "$gold_file")
  stratum_2=$(jq -s -r '[.[] | select(.conv_id=="2060" and .turn_index==2)][0].stratum' "$gold_file")
  [ "$first_tool_0" = "tool_a" ]
  [ "$first_tool_2" = "tool_b" ]
  [ "$stratum_2" = "tool" ]
}

@test "caroline_action.replied is per-turn, not conversation-wide" {
  # conv-2040: idx0 (customer) is immediately answered by Caroline
  # (bot-admin-1) at idx1; idx2 (customer, a closer) gets no reply at all.
  # The OLD conv-level "replied = any bot/admin part anywhere" would read
  # true for BOTH turns (idx1 exists somewhere in the conv); the per-turn
  # fix must read idx0=true (a reply follows before the next customer part)
  # and idx2=false (nothing follows it).
  cat > "$TEST_TMPDIR/convs/2040.json" <<'JSON'
{
  "id": "2040",
  "source": {"author": {"type": "user", "id": "u4"}, "body": "quick question about billing", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "here is your answer", "created_at": 110, "attachments": []},
    {"part_type": "comment", "author": {"type": "user", "id": "u4"}, "body": "thanks, that is all, bye", "created_at": 120, "attachments": []}
  ]}
}
JSON
  printf '2040\n' > "$TEST_TMPDIR/search-ids.txt"

  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  replied_0=$(jq -s -r '[.[] | select(.conv_id=="2040" and .turn_index==0)][0].caroline_action.replied' "$gold_file")
  replied_2=$(jq -s -r '[.[] | select(.conv_id=="2040" and .turn_index==2)][0].caroline_action.replied' "$gold_file")
  [ "$replied_0" = "true" ]
  [ "$replied_2" = "false" ]
}

@test "an --apply-review human verdict with a made-up intent or tool is skipped, not merged" {
  # A human verdict gets the same enum check as the labeller's own output: a
  # typo must not become gold just because a person typed it.
  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  review_file=$(find "$JEV_EVAL_DIR" -name 'review-*.md')
  cp "$gold_file" "$TEST_TMPDIR/gold-before.jsonl"
  conv_id=$(head -n1 "$gold_file" | jq -r '.conv_id')
  turn_index=$(head -n1 "$gold_file" | jq -r '.turn_index')
  human_label='{"path":"caroline_tool","intent":"made_up_intent","first_tool":"hallucinated_tool","needs_reply":true,"supplying_requested_info":false,"bad_faith":false,"frustration_level":0,"rationale":"human override"}'
  { echo "### conv=${conv_id} turn=${turn_index}"; echo; echo "verdict: ${human_label}"; echo; } >> "$review_file"

  run "$SCRIPT" --apply-review "$review_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN verdict"* ]]
  [ "$(jq -S -c '.' "$TEST_TMPDIR/gold-before.jsonl" | sort)" = "$(jq -S -c '.' "$gold_file" | sort)" ]
}

@test "a valid no_reply label on a turn Caroline actually answered goes to the review queue" {
  # no_reply requires needs_reply=false, so the review check must compare the
  # label with what Caroline did, not with the label's own needs_reply.
  lib="$TEST_TMPDIR/lib.py"
  awk '/^cat > "\$PY_SCRIPT" <<.PYEOF.$/{on=1; next} on && /^PYEOF$/{exit} on' "$SCRIPT" > "$lib"
  [ -s "$lib" ]
  run python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lib", sys.argv[1]); m = importlib.util.module_from_spec(spec)
sys.argv = ["lib"]; spec.loader.exec_module(m)
label = {"path": "no_reply", "needs_reply": False}
print(m.disagrees(label, {"replied": True}), m.disagrees(label, {"replied": False}))
' "$lib"
  [ "$status" -eq 0 ]
  [ "$output" = "True False" ]
}

@test "a path=no_reply label with needs_reply=true is now caught upstream as cross-field inconsistent, both turns go to review (QA re-review finding 2 changed this scenario's outcome)" {
  # Same conv-2040 shape as the original version of this test. Before
  # finding 2, disagrees()'s `path=="no_reply" and needs_reply and replied`
  # branch used caroline_action.replied (a per-turn field) to flag ONLY the
  # replied-to turn (idx0), never the closer (idx2) -- the regression this
  # test originally defended (a conv-wide `replied` bug had flagged both).
  # Finding 2 makes path=no_reply + needs_reply=true itself an invalid,
  # self-contradictory label (the doctrine defines needs_reply as "a
  # correct agent would send a message", which no_reply by definition
  # contradicts) -- validate_label's caller now nulls the label out BEFORE
  # disagrees() ever runs, so disagrees()'s no_reply branch is no longer
  # reachable through this fixture, and per-turn `replied` correctness is
  # covered instead by "caroline_action.replied is per-turn, not
  # conversation-wide" above. What this test defends now: an inconsistent
  # label is flagged with kind=inconsistent and sent to review for BOTH
  # turns (label=null always disagrees), never silently kept as gold.
  FAKE_LABEL_MODE=no_reply_needs_reply
  export FAKE_LABEL_MODE
  cat > "$TEST_TMPDIR/convs/2040.json" <<'JSON'
{
  "id": "2040",
  "source": {"author": {"type": "user", "id": "u4"}, "body": "quick question about billing", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "here is your answer", "created_at": 110, "attachments": []},
    {"part_type": "comment", "author": {"type": "user", "id": "u4"}, "body": "thanks, that is all, bye", "created_at": 120, "attachments": []}
  ]}
}
JSON
  printf '2040\n' > "$TEST_TMPDIR/search-ids.txt"

  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  review_file=$(find "$JEV_EVAL_DIR" -name 'review-*.md')
  [[ "$(cat "$review_file")" == *"### conv=2040 turn=0"* ]]
  [[ "$(cat "$review_file")" == *"### conv=2040 turn=2"* ]]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  kind_0=$(jq -s -r '[.[] | select(.conv_id=="2040" and .turn_index==0)][0].label_error.kind' "$gold_file")
  kind_2=$(jq -s -r '[.[] | select(.conv_id=="2040" and .turn_index==2)][0].label_error.kind' "$gold_file")
  [ "$kind_0" = "inconsistent" ]
  [ "$kind_2" = "inconsistent" ]
}

@test "a cross-field inconsistent label is unlabelled with kind=inconsistent, never scored as-is (QA re-review finding 2)" {
  # Three violation shapes in one conversation's three customer turns:
  # idx0 gets path=caroline_tool with first_tool=none (caroline_tool
  # requires a REAL tool, never none/memory_search); idx2 (via a second
  # conv) gets path=acknowledge with needs_reply=false (acknowledge
  # requires needs_reply=true); idx4 (a third conv) gets
  # path=answer_from_knowledge with first_tool=credits_lookup (must be
  # memory_search or none). All three are schema-VALID per validate_label
  # (right types, in-enum values) -- only the cross-field relationship is
  # wrong, so this exercises label_consistency_error specifically, not the
  # pre-existing per-field schema/enum checks.
  FAKE_LABEL_MODE=caroline_tool_no_first_tool
  export FAKE_LABEL_MODE
  cat > "$TEST_TMPDIR/convs/2090.json" <<'JSON'
{
  "id": "2090",
  "source": {"author": {"type": "user", "id": "u90"}, "body": "where are my credits", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "let me check that for you", "created_at": 110, "attachments": []}
  ]}
}
JSON
  printf '2090\n' > "$TEST_TMPDIR/search-ids.txt"

  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  label=$(jq -s -r '[.[] | select(.conv_id=="2090" and .turn_index==0)][0].label' "$gold_file")
  kind=$(jq -s -r '[.[] | select(.conv_id=="2090" and .turn_index==0)][0].label_error.kind' "$gold_file")
  [ "$label" = "null" ]
  [ "$kind" = "inconsistent" ]
}

@test "sampling within a stratum is deterministic for a fixed seed and is not simply the lowest conv_ids (QA re-review finding 5)" {
  # 12 single-turn "first"-stratum conversations (unique bodies carry a '?'
  # so is_closer_text() can never mistake one for a closer, regardless of
  # phrase list). Before the fix, cmd_sample ordered each stratum's pool by
  # plain (conv_id, turn_index) -- a live gold set built this way is biased
  # toward whichever conversations happen to sort first, every single run.
  # The fix orders by sha256(seed, conv_id, turn_index) instead: this test
  # asserts (a) the same --seed picks the same rows on two separate runs,
  # and (b) the picked rows are NOT just the 4 lowest conv_ids in sorted
  # order (which would mean the hash reordering never actually took hold).
  ids=""
  for n in $(seq 3300 3311); do
    cat > "$TEST_TMPDIR/convs/${n}.json" <<JSON
{
  "id": "${n}",
  "source": {"author": {"type": "user", "id": "u${n}"}, "body": "question ${n} about my account?", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "let me check that for you", "created_at": 110, "attachments": []}
  ]}
}
JSON
    ids="${ids}${n}\n"
  done
  printf "$ids" > "$TEST_TMPDIR/search-ids.txt"

  run "$SCRIPT" --days 30 --size 4 --seed 777
  [ "$status" -eq 0 ]
  gold_file_a=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  picked_a=$(jq -r '.conv_id' "$gold_file_a" | sort)
  rm -rf "$JEV_EVAL_DIR"
  mkdir -p "$JEV_EVAL_DIR"

  run "$SCRIPT" --days 30 --size 4 --seed 777
  [ "$status" -eq 0 ]
  gold_file_b=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  picked_b=$(jq -r '.conv_id' "$gold_file_b" | sort)

  [ "$picked_a" = "$picked_b" ]
  lowest_four="$(printf '3300\n3301\n3302\n3303')"
  [ "$picked_a" != "$lowest_four" ]
}

@test "the closer stratum uses production's exact-phrase predicate, never the removed short/no-'?' fallback (QA re-review finding 4)" {
  # Each conversation's LAST customer turn is short and has no '?' -- the
  # removed jev-router.ts fallback (any message <=3 words, no '?') would
  # have wrongly stratified all three as "closer". Production's real-data
  # false positives were exactly this shape (docs/designs/2026-09-22-jev-
  # caroline-router.md): "urgent" after an escalation, and a bare profile
  # link, both scored as closers and both needed a reply.
  cat > "$TEST_TMPDIR/convs/2070.json" <<'JSON'
{
  "id": "2070",
  "source": {"author": {"type": "user", "id": "u7"}, "body": "I have not received my credits", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "let me check that for you", "created_at": 110, "attachments": []},
    {"part_type": "comment", "author": {"type": "user", "id": "u7"}, "body": "credits still missing", "created_at": 120, "attachments": []}
  ]}
}
JSON
  cat > "$TEST_TMPDIR/convs/2071.json" <<'JSON'
{
  "id": "2071",
  "source": {"author": {"type": "user", "id": "u8"}, "body": "I have not received my credits", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "let me check that for you", "created_at": 110, "attachments": []},
    {"part_type": "comment", "author": {"type": "user", "id": "u8"}, "body": "urgent", "created_at": 120, "attachments": []}
  ]}
}
JSON
  cat > "$TEST_TMPDIR/convs/2072.json" <<'JSON'
{
  "id": "2072",
  "source": {"author": {"type": "user", "id": "u9"}, "body": "I have not received my credits", "created_at": 100, "attachments": []},
  "conversation_parts": {"conversation_parts": [
    {"part_type": "comment", "author": {"type": "admin", "id": "bot-admin-1"}, "body": "let me check that for you", "created_at": 110, "attachments": []},
    {"part_type": "comment", "author": {"type": "user", "id": "u9"}, "body": "https://app.muso.ai/profile/abc123", "created_at": 120, "attachments": []}
  ]}
}
JSON
  printf '2070\n2071\n2072\n' > "$TEST_TMPDIR/search-ids.txt"

  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  # Each conversation has TWO customer turns (index 0's opener, index 2's
  # short closing reply -- index 1 is the bot's comment, never a customer
  # turn_index). The row under test is the last customer turn, index 2; a
  # query for the wrong index would silently select nothing and let
  # `[0].stratum` read null, which also satisfies `!= "closer"` -- so this
  # also asserts the row was actually sampled, to rule that out.
  stratum_2070=$(jq -s -r '[.[] | select(.conv_id=="2070" and .turn_index==2)][0].stratum' "$gold_file")
  stratum_2071=$(jq -s -r '[.[] | select(.conv_id=="2071" and .turn_index==2)][0].stratum' "$gold_file")
  stratum_2072=$(jq -s -r '[.[] | select(.conv_id=="2072" and .turn_index==2)][0].stratum' "$gold_file")
  [ -n "$stratum_2070" ] && [ "$stratum_2070" != "null" ]
  [ -n "$stratum_2071" ] && [ "$stratum_2071" != "null" ]
  [ -n "$stratum_2072" ] && [ "$stratum_2072" != "null" ]
  [ "$stratum_2070" != "closer" ]
  [ "$stratum_2071" != "closer" ]
  [ "$stratum_2072" != "closer" ]
}

@test "a system prompt larger than the kernel's single-argument limit still labels every row" {
  # Production SOUL.md + inventory is far past MAX_ARG_STRLEN (128 KiB) once
  # both are inlined; passing it to jq/curl as an argv string dies with
  # "Argument list too long". 1.1 MB exceeds both the Linux per-argument
  # limit and the macOS total ARG_MAX, so this goes red on either host.
  big_soul="$TEST_TMPDIR/big-soul.md"
  cat "$FIXTURES/soul.md" > "$big_soul"
  head -c 1100000 /dev/zero | tr '\0' 'x' >> "$big_soul"
  export JEV_EVAL_SOUL_FILE="$big_soul"

  run "$SCRIPT" --days 21 --size 10
  [ "$status" -eq 0 ]
  [[ "$output" != *"Argument list too long"* ]]
  gold="$(ls "$JEV_EVAL_DIR"/caroline-gold-*.jsonl)"
  [ "$(jq -s '[.[] | select(.label == null)] | length' "$gold")" -eq 0 ]
}

@test "a finish_reason=length truncation is recorded as a label_error, not a silent null" {
  # openai/gpt-5.6-sol is a reasoning model: max_tokens too small cuts the
  # completion off mid-JSON. The row must still carry label_error with the
  # right kind and the diagnostic fields -- never just label=null with no
  # trace of why.
  FAKE_LABEL_FAIL_ON_CALL=2 FAKE_LABEL_FAIL_MODE=truncated run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  n_rows=$(grep -c . "$gold_file")
  [ "$n_rows" -eq 5 ]

  err=$(jq -s '[.[] | select(.label == null)][0].label_error' "$gold_file")
  kind=$(echo "$err" | jq -r '.kind')
  [ "$kind" = "truncated" ]
  finish_reason=$(echo "$err" | jq -r '.finish_reason')
  [ "$finish_reason" = "length" ]
  raw_content=$(echo "$err" | jq -r '.raw_content')
  [[ "$raw_content" == *"caroline_tool"* ]]
  http_status=$(echo "$err" | jq -r '.http_status')
  [ "$http_status" = "200" ]

  [[ "$output" == *"label errors by kind:"* ]]
  [[ "$output" == *"truncated: 1"* ]]
}

@test "--relabel fills only the null rows and leaves labelled rows byte-identical" {
  FAKE_LABEL_FAIL_ON_CALL=2 FAKE_LABEL_FAIL_MODE=truncated run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')

  # Snapshot the RAW lines (no jq re-serialization on either side of this
  # comparison, so a re-dump that only reorders keys or reformats
  # whitespace -- not just one that changes a value -- is still caught).
  n_lines_before=$(wc -l < "$gold_file" | tr -d ' ')
  # Line 1 is the null row here (turn order == sample order, conv 2001
  # first). Lines 2-5 are the already-labelled rows.
  cp "$gold_file" "$TEST_TMPDIR/gold-before-raw.jsonl"

  n_null_before=$(jq -s '[.[] | select(.label == null)] | length' "$gold_file")
  [ "$n_null_before" -eq 1 ]
  null_line_no=$(grep -n '"label":null' "$gold_file" | cut -d: -f1 | head -1)
  [ -n "$null_line_no" ]

  # Relabel with the stub back in "ok" mode -- the null row should now get a
  # real label.
  unset FAKE_LABEL_FAIL_ON_CALL FAKE_LABEL_FAIL_MODE
  export FAKE_LABEL_MODE=ok
  run "$SCRIPT" --relabel "$gold_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"attempted=1 fixed=1"* ]]

  n_lines_after=$(wc -l < "$gold_file" | tr -d ' ')
  [ "$n_lines_before" -eq "$n_lines_after" ]

  n_null_after=$(jq -s '[.[] | select(.label == null)] | length' "$gold_file")
  [ "$n_null_after" -eq 0 ]

  # Every line EXCEPT the one that was null must be the exact same bytes as
  # before -- proves relabel never re-serializes a row it didn't touch.
  i=0
  while IFS= read -r before_line; do
    i=$((i + 1))
    after_line=$(sed -n "${i}p" "$gold_file")
    if [ "$i" -eq "$null_line_no" ]; then
      [ "$before_line" != "$after_line" ]
    else
      [ "$before_line" = "$after_line" ]
    fi
  done < "$TEST_TMPDIR/gold-before-raw.jsonl"

  perm=$(stat -c '%a' "$gold_file" 2>/dev/null || stat -f '%Lp' "$gold_file" 2>/dev/null)
  [ "$perm" = "600" ]
}

@test "--relabel on a row with no stored full_thread is skipped, not crashed" {
  run "$SCRIPT" --days 30 --size 10
  [ "$status" -eq 0 ]
  gold_file=$(find "$JEV_EVAL_DIR" -name 'caroline-gold-*.jsonl')
  # Simulate a pre-fix gold row (no full_thread) with a null label.
  legacy_file="$TEST_TMPDIR/legacy-gold.jsonl"
  jq -c 'del(.full_thread) | .label = null | .label_error = null' "$gold_file" | head -n1 > "$legacy_file"

  run "$SCRIPT" --relabel "$legacy_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has no full_thread stored"* ]]
  kind=$(jq -r '.label_error.kind' "$legacy_file")
  [ "$kind" = "missing_full_thread" ]
}
