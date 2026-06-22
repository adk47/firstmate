#!/usr/bin/env bats
# Plain-text rendering (--text): the announce fallback. The rendered text must
# pass the LEGACY gates (redact-output.sh | linkify-convs.sh |
# assert-digest-contract.sh) — the header is computed, the contract proves it.
load helpers

setup() {
  setup_skill_tmp
  setup_digest_fixtures
}
teardown() { teardown_skill_tmp; }

render_text() {  # $1 = digest file
  run bash -c "\"$SCRIPTS_DIR/render-digest.py\" --text < \"$1\" \
    | \"$SCRIPTS_DIR/redact-output.sh\" \
    | \"$SCRIPTS_DIR/linkify-convs.sh\" \
    | \"$SCRIPTS_DIR/assert-digest-contract.sh\""
}

@test "quiet daily digest renders and passes the legacy contract pipeline" {
  render_text "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  first_line="${output%%$'\n'*}"
  [[ "$first_line" == "🟢 Caroline daily"* ]]
  [[ "$first_line" == *"23 convs"* ]]
  [[ "$first_line" == *"0 P0 / 0 P1 / 1 P2"* ]]
  [[ "$first_line" != *"U0AL36NADEY"* ]]
}

@test "scores line renders Tools skipped and the guard counts" {
  render_text "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tools skipped"* ]]
  [[ "$output" == *"Guard 0/0"* ]]
}

@test "P0 digest prepends the reviewer ping and renders an action section" {
  jq '.severity = {"p0":1,"p1":0,"p2":0}
      | .findings += [{"dimension":"voice","severity":"P0","text":"email leak shipped to customer","conversation_ids":["215474000000001"]}]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/p0.json"
  render_text "$WORKDIR/p0.json"
  [ "$status" -eq 0 ]
  first_line="${output%%$'\n'*}"
  [[ "$first_line" == "<@U0AL36NADEY> 🔴 Caroline daily"* ]]
  [[ "$output" == *"*Action needed*"* ]]
  [[ "$output" == *"email leak shipped to customer (Voice)"* ]]
}

@test "conversation ids are stripped from prose and render once as numbered links" {
  jq '.findings[0].text = "1 frustrated in conv 215474000000002 today"' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/dup.json"
  render_text "$WORKDIR/dup.json"
  [ "$status" -eq 0 ]
  # the id appears ONLY inside the link URL, never as standalone prose
  [[ "$output" == *"<https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/215474000000002|1>"* ]]
  [[ "$output" != *"conv 215474000000002"* ]]
  [[ "$output" != *"215474000000002 today"* ]]
}

@test "INTERCOM_WORKSPACE_ID overrides the workspace in the deep-link prefix" {
  output="$(INTERCOM_WORKSPACE_ID=zzzz "$SCRIPTS_DIR/render-digest.py" --text < "$WORKDIR/digest-daily.json")"
  [[ "$output" == *"https://app.intercom.com/a/inbox/zzzz/inbox/conversation/215474000000002"* ]]
  [[ "$output" != *"/inbox/dwjzhcge/"* ]]
}

@test "evidence links are numbered and capped at 3 with a +N overflow" {
  jq '.themes[0].conversation_ids = ["215474000000001","215474000000002","215474000000003","215474000000004","215474000000005"]' \
    "$WORKDIR/digest-daily.json" > "$WORKDIR/many.json"
  render_text "$WORKDIR/many.json"
  [ "$status" -eq 0 ]
  theme_line="$(printf '%s' "$output" | grep "Spotify sync stuck")"
  [[ "$theme_line" == *"|1>"* && "$theme_line" == *"|2>"* && "$theme_line" == *"|3>"* ]]
  [[ "$theme_line" == *"+2"* ]]
  [[ "$theme_line" != *"|4>"* ]]
}

@test "clean dimensions are collapsed (no Voice detail bullet without findings)" {
  render_text "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"*Voice*:"* ]]
  [[ "$output" == *"*Sentiment*"* ]]
}

@test "guard line is always present, healthy form when all zero" {
  render_text "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"*Guard* - healthy: 0 caught, 0 missed"* ]]
}

@test "degraded guard source is surfaced on the guard line" {
  jq '.guard.source = "syslog"' "$WORKDIR/digest-daily.json" > "$WORKDIR/deg.json"
  render_text "$WORKDIR/deg.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"degraded: syslog"* ]]
}

@test "themes render label, summary, customer count" {
  render_text "$WORKDIR/digest-daily.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"*Themes*"* ]]
  [[ "$output" == *"*Spotify sync stuck*"* ]]
  [[ "$output" == *"*2 customers*"* ]]
}

@test "themes section is omitted when there are no themes" {
  jq '.themes = []' "$WORKDIR/digest-daily.json" > "$WORKDIR/nothemes.json"
  render_text "$WORKDIR/nothemes.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Themes"* ]]
}

@test "weekly digest renders the roll-up title, day window and KB candidates" {
  render_text "$WORKDIR/digest-weekly.json"
  [ "$status" -eq 0 ]
  first_line="${output%%$'\n'*}"
  [[ "$first_line" == *"Caroline weekly roll-up"* ]]
  [[ "$first_line" == *"last 7d"* ]]
  [[ "$output" == *"*KB-gap candidates*"* ]]
  [[ "$output" == *"How royalties accrue"* ]]
}

@test "guard items render as action bullets and guard detail" {
  render_text "$WORKDIR/digest-weekly.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Escalated"* ]]
  [[ "$output" == *"215474000000099"* ]]
}
