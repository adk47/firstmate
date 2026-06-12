#!/usr/bin/env bats
# Block Kit rendering: --blocks-main (the lean glance) and --blocks-thread
# (the detail reply) — complete chat.postMessage payloads built
# deterministically from the digest.
load helpers

setup() {
  setup_skill_tmp
  setup_digest_fixtures
  unset CAROLINE_DIGEST_CHANNEL || true
}
teardown() { teardown_skill_tmp; }

main_blocks() {  # $1 = digest file -> $WORKDIR/payload.json
  "$SCRIPTS_DIR/render-digest.py" --blocks-main < "$1" > "$WORKDIR/payload.json"
}
thread_blocks() {  # $1 = digest file -> $WORKDIR/thread.json
  "$SCRIPTS_DIR/render-digest.py" --blocks-thread < "$1" > "$WORKDIR/thread.json"
}

@test "main payload is valid JSON with default channel, fallback text and blocks" {
  main_blocks "$WORKDIR/digest-daily.json"
  jq -e '.channel == "C0ANM0PN9L5"' "$WORKDIR/payload.json"
  jq -e '.unfurl_links == false and .unfurl_media == false' "$WORKDIR/payload.json"
  text="$(jq -r '.text' "$WORKDIR/payload.json")"
  [[ "$text" == *"23 convs"* ]]
  [[ "$text" == *"0 P0 / 0 P1 / 1 P2"* ]]
}

@test "CAROLINE_DIGEST_CHANNEL overrides the target channel (shadow rollout)" {
  CAROLINE_DIGEST_CHANNEL="C0SHADOW123" \
    "$SCRIPTS_DIR/render-digest.py" --blocks-main < "$WORKDIR/digest-daily.json" > "$WORKDIR/payload.json"
  jq -e '.channel == "C0SHADOW123"' "$WORKDIR/payload.json"
}

@test "header block carries the status emoji and window" {
  main_blocks "$WORKDIR/digest-daily.json"
  header="$(jq -r '.blocks[] | select(.type == "header") | .text.text' "$WORKDIR/payload.json")"
  [[ "$header" == "🟢 Caroline daily"* ]]
  [[ "$header" == *"last 30h"* ]]
}

@test "compact summary section replaces the fields grid" {
  main_blocks "$WORKDIR/digest-daily.json"
  jq -e '[.blocks[] | select(.fields)] | length == 0' "$WORKDIR/payload.json"
  summary="$(jq -r '.blocks[] | select(.type == "section") | .text.text' "$WORKDIR/payload.json" | grep "Convs")"
  [[ "$summary" == *"*Convs* 23"* ]]
}

@test "no ping, no action block, no mention anywhere on a clean day" {
  main_blocks "$WORKDIR/digest-daily.json"
  run grep -c "U0AL36NADEY" "$WORKDIR/payload.json"
  [ "$output" = "0" ]
  run grep -c "action needed" "$WORKDIR/payload.json"
  [ "$output" = "0" ]
}

@test "P0/P1 findings and guard items lead the main payload as action bullets" {
  jq '.severity = {"p0":1,"p1":1,"p2":1}
      | .findings += [{"dimension":"voice","severity":"P0","text":"email leak shipped to customer","conversation_ids":["215474000000001"]}]
      | .guard.items = [{"type":"unanswered_escalation","conversation_id":"215474000000099"}]
      | .guard.caught_escalated = 1' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/p0.json"
  main_blocks "$WORKDIR/p0.json"
  jq -e '.blocks[0].type == "section"' "$WORKDIR/payload.json"
  first="$(jq -r '.blocks[0].text.text' "$WORKDIR/payload.json")"
  [[ "$first" == "<@U0AL36NADEY> 🔴 *1 P0 / 1 P1 - action needed*"* ]]
  [[ "$first" == *"email leak shipped to customer (Voice)"* ]]
  [[ "$first" == *"Escalated, still unanswered by a human (Guard)"* ]]
  # P0 bullet sorts before the P1 guard bullet
  [[ "${first#*• email leak}" == *"Escalated"* ]]
  [[ "$(jq -r '.text' "$WORKDIR/payload.json")" == "<@U0AL36NADEY>"* ]]
}

@test "P1-only day renders the action block WITHOUT a ping" {
  jq '.severity = {"p0":0,"p1":1,"p2":1}
      | .findings += [{"dimension":"tools","severity":"P1","text":"missed profile_status call","conversation_ids":["215474000000001"]}]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/p1.json"
  main_blocks "$WORKDIR/p1.json"
  first="$(jq -r '.blocks[0].text.text' "$WORKDIR/payload.json")"
  [[ "$first" == "🟡 *0 P0 / 1 P1 - action needed*"* ]]
  run grep -c "U0AL36NADEY" "$WORKDIR/payload.json"
  [ "$output" = "0" ]
}

@test "main theme bullets: emoji label, bold count, links capped at 3 with +N" {
  jq '.themes[0].conversation_ids = ["215474000000001","215474000000002","215474000000003","215474000000004","215474000000005"]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/many.json"
  main_blocks "$WORKDIR/many.json"
  themes="$(jq -r '.blocks[] | select(.type == "section" and (.text.text // "" | contains("Themes"))) | .text.text' "$WORKDIR/payload.json")"
  [[ "$themes" == *"🐛 *Spotify sync stuck*"* ]]
  [[ "$themes" == *"*2 customers*"* ]]
  [[ "$themes" == *"|3>"* ]]
  [[ "$themes" == *"+2"* ]]
  [[ "$themes" != *"|4>"* ]]
}

@test "main payload contains NO P2 detail sections (they live in the thread)" {
  main_blocks "$WORKDIR/digest-daily.json"
  run grep -c "Sentiment\*:" "$WORKDIR/payload.json"
  [ "$output" = "0" ]
  run grep -c "Good catch" "$WORKDIR/payload.json"
  [ "$output" = "0" ]
}

@test "ids in prose are stripped in the main payload" {
  jq '.findings[0].text = "1 frustrated in conv 215474000000002"
      | .findings[0].severity = "P1" | .severity.p1 = 1' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/dup.json"
  main_blocks "$WORKDIR/dup.json"
  first="$(jq -r '.blocks[0].text.text' "$WORKDIR/payload.json")"
  [[ "$first" == *"1 frustrated (Sentiment)"* ]]
  [[ "$first" != *"conv 215474000000002"* ]]
}

@test "thread payload: lead context, P2 details, good catch, uncapped theme evidence" {
  jq '.themes[0].conversation_ids = ["215474000000001","215474000000002","215474000000003","215474000000004","215474000000005"]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/many.json"
  thread_blocks "$WORKDIR/many.json"
  jq -e '.blocks[0].type == "context"' "$WORKDIR/thread.json"
  body="$(jq -r '[.blocks[] | select(.type == "section") | .text.text] | join("\n")' "$WORKDIR/thread.json")"
  [[ "$body" == *"*Sentiment*"* ]]
  [[ "$body" == *"*Good catch*"* ]]
  [[ "$body" == *"Theme evidence"* ]]
  [[ "$body" == *"|5>"* ]]   # uncapped: all 5 links render
  [[ "$body" != *"+2"* ]]
  run grep -c "U0AL36NADEY" "$WORKDIR/thread.json"
  [ "$output" = "0" ]
  run jq -e '[.blocks[] | select(.type == "header")] | length == 0' "$WORKDIR/thread.json"
  [ "$status" -eq 0 ]
}

@test "thread payload on a truly quiet day has only the lead context block" {
  jq '.findings = [] | .themes = []' "$WORKDIR/digest-daily.json" > "$WORKDIR/quiet.json"
  thread_blocks "$WORKDIR/quiet.json"
  jq -e '.blocks | length == 1' "$WORKDIR/thread.json"
}

@test "weekly main groups themes; thread carries KB candidates with proposed note" {
  main_blocks "$WORKDIR/digest-weekly.json"
  payload="$(jq -r '[.blocks[] | select(.type == "section") | .text.text] | join("\n")' "$WORKDIR/payload.json")"
  [[ "$payload" == *"Feature asks"* ]]
  [[ "$payload" != *"KB-gap candidates"* ]]
  thread_blocks "$WORKDIR/digest-weekly.json"
  tbody="$(jq -r '[.blocks[] | select(.type == "section") | .text.text] | join("\n")' "$WORKDIR/thread.json")"
  [[ "$tbody" == *"KB-gap candidates"* ]]
  [[ "$tbody" == *"_proposed note:_ Royalties accrue when"* ]]
  [[ "$tbody" == *"Auto-PR disabled in v1"* ]]
}

@test "context footer names the job, window and guard source; degraded notes surface" {
  jq '.degraded = ["conv fetch hit the 200 cap - window under-sampled"]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/deg.json"
  main_blocks "$WORKDIR/deg.json"
  ctx="$(jq -r '.blocks[-1] | select(.type == "context") | .elements[0].text' "$WORKDIR/payload.json")"
  [[ "$ctx" == *"caroline-daily-review"* ]]
  [[ "$ctx" == *"guard source journalctl"* ]]
  [[ "$ctx" == *"200 cap"* ]]
}

@test "oversize section text is truncated with a counted marker, never silently" {
  long_text="$(python3 -c "print('word ' * 1200)")"
  jq --arg t "$long_text" \
    '.findings += [{"dimension":"voice","severity":"P2","text":$t,"conversation_ids":[]}]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/long.json"
  thread_blocks "$WORKDIR/long.json"
  jq -e '[.blocks[] | select(.type == "section" and .text) | .text.text | length] | max <= 3000' "$WORKDIR/thread.json"
}

@test "long theme summary is truncated to ~100 chars in the main bullet" {
  long_summary="$(python3 -c "print('s' * 300)")"
  jq --arg s "$long_summary" '.themes[0].summary = $s' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/longsum.json"
  main_blocks "$WORKDIR/longsum.json"
  themes="$(jq -r '.blocks[] | select(.type == "section" and (.text.text // "" | contains("Themes"))) | .text.text' "$WORKDIR/payload.json")"
  [[ "$themes" == *"…"* ]]
  [[ "$themes" != *"$(python3 -c "print('s' * 150)")"* ]]
}
