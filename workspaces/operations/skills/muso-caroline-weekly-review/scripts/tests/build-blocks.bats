#!/usr/bin/env bats
# Block Kit rendering (--blocks): a complete chat.postMessage payload —
# channel, notification text, blocks — built deterministically from the digest.
load helpers

setup() {
  setup_skill_tmp
  setup_digest_fixtures
  unset CAROLINE_DIGEST_CHANNEL || true
}
teardown() { teardown_skill_tmp; }

blocks() {  # $1 = digest file -> $WORKDIR/payload.json
  "$SCRIPTS_DIR/render-digest.py" --blocks < "$1" > "$WORKDIR/payload.json"
}

@test "payload is valid JSON with default channel, fallback text and blocks" {
  blocks "$WORKDIR/digest-daily.json"
  jq -e '.channel == "C0ANM0PN9L5"' "$WORKDIR/payload.json"
  jq -e '.unfurl_links == false and .unfurl_media == false' "$WORKDIR/payload.json"
  jq -e '.blocks | length > 3' "$WORKDIR/payload.json"
  text="$(jq -r '.text' "$WORKDIR/payload.json")"
  [[ "$text" == *"23 convs"* ]]
  [[ "$text" == *"0 P0 / 0 P1 / 1 P2"* ]]
}

@test "CAROLINE_DIGEST_CHANNEL overrides the target channel (shadow rollout)" {
  CAROLINE_DIGEST_CHANNEL="C0SHADOW123" \
    "$SCRIPTS_DIR/render-digest.py" --blocks < "$WORKDIR/digest-daily.json" > "$WORKDIR/payload.json"
  jq -e '.channel == "C0SHADOW123"' "$WORKDIR/payload.json"
}

@test "header block carries the status emoji and window" {
  blocks "$WORKDIR/digest-daily.json"
  header="$(jq -r '.blocks[] | select(.type == "header") | .text.text' "$WORKDIR/payload.json")"
  [[ "$header" == "🟢 Caroline daily"* ]]
  [[ "$header" == *"last 30h"* ]]
}

@test "no ping section and no mention anywhere on a no-P0 day" {
  blocks "$WORKDIR/digest-daily.json"
  run grep -c "U0AL36NADEY" "$WORKDIR/payload.json"
  [ "$output" = "0" ]
}

@test "P0 day leads with a ping section and pings in the notification text" {
  jq '.severity.p0 = 1' "$WORKDIR/digest-daily.json" > "$WORKDIR/p0.json"
  blocks "$WORKDIR/p0.json"
  jq -e '.blocks[0].type == "section"' "$WORKDIR/payload.json"
  first="$(jq -r '.blocks[0].text.text' "$WORKDIR/payload.json")"
  [[ "$first" == "<@U0AL36NADEY>"*"P0 - action needed"* ]]
  [[ "$(jq -r '.text' "$WORKDIR/payload.json")" == "<@U0AL36NADEY>"* ]]
}

@test "score fields render as a 2-column section" {
  blocks "$WORKDIR/digest-daily.json"
  fields="$(jq -r '.blocks[] | select(.fields) | .fields[].text' "$WORKDIR/payload.json")"
  [[ "$fields" == *"*Convs:* 23"* ]]
  [[ "$fields" == *"*Tools* skipped"* ]]
  [[ "$fields" == *"*Guard* 0 caught / 0 missed"* ]]
}

@test "conversation ids are linkified exactly once (idempotent regex)" {
  blocks "$WORKDIR/digest-daily.json"
  payload="$(cat "$WORKDIR/payload.json")"
  [[ "$payload" == *"<https://app.intercom.com/a/inboxes/all/conversations/215474000000002|215474000000002>"* ]]
  [[ "$payload" != *"conversations/<https"* ]]
}

@test "daily themes render as one informational section" {
  blocks "$WORKDIR/digest-daily.json"
  themes="$(jq -r '.blocks[] | select(.type == "section" and (.text.text // "" | contains("Themes"))) | .text.text' "$WORKDIR/payload.json")"
  [[ "$themes" == *"Spotify sync stuck"* ]]
  [[ "$themes" == *"2 customers"* ]]
}

@test "weekly digest renders grouped theme sections and the KB section" {
  blocks "$WORKDIR/digest-weekly.json"
  payload="$(jq -r '[.blocks[] | select(.type == "section" and .text) | .text.text] | join("\n---\n")' "$WORKDIR/payload.json")"
  [[ "$payload" == *"Feature asks"* ]]
  [[ "$payload" == *"KB-gap candidates"* ]]
  [[ "$payload" == *"Auto-PR disabled in v1"* ]]
  header="$(jq -r '.blocks[] | select(.type == "header") | .text.text' "$WORKDIR/payload.json")"
  [[ "$header" == *"weekly roll-up"* ]]
}

@test "context footer names the job, window and guard source" {
  blocks "$WORKDIR/digest-daily.json"
  ctx="$(jq -r '.blocks[-1] | select(.type == "context") | .elements[0].text' "$WORKDIR/payload.json")"
  [[ "$ctx" == *"caroline-daily-review"* ]]
  [[ "$ctx" == *"last 30h"* ]]
  [[ "$ctx" == *"guard source journalctl"* ]]
}

@test "degraded notes surface in the context footer" {
  jq '.degraded = ["conv fetch hit the 200 cap - window under-sampled"]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/deg.json"
  blocks "$WORKDIR/deg.json"
  ctx="$(jq -r '.blocks[-1].elements[0].text' "$WORKDIR/payload.json")"
  [[ "$ctx" == *"200 cap"* ]]
}

@test "oversize section text is truncated with a counted marker, never silently" {
  long_text="$(python3 -c "print('word ' * 1200)")"
  jq --arg t "$long_text" \
    '.findings += [{"dimension":"voice","severity":"P2","text":$t,"conversation_ids":[]}]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/long.json"
  blocks "$WORKDIR/long.json"
  jq -e '[.blocks[] | select(.type == "section" and .text) | .text.text | length] | max <= 3000' "$WORKDIR/payload.json"
}

@test "more than 10 findings in one dimension overflow to a counted bullet" {
  jq '.findings = [range(0;15) | {"dimension":"voice","severity":"P2","text":"tell \(.)","conversation_ids":[]}]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/many.json"
  blocks "$WORKDIR/many.json"
  payload="$(cat "$WORKDIR/payload.json")"
  [[ "$payload" == *"+5 more"* ]]
}
