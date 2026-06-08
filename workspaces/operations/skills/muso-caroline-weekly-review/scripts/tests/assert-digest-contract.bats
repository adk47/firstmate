#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }
teardown() { teardown_skill_tmp; }

# Run the guard with $1 as stdin; $output captures stdout+stderr (bats merges them).
run_guard() {
  printf '%s' "$1" > "$TEST_TMPDIR/digest.txt"
  run bash -c '"$1" < "$2"' _ "$SCRIPTS_DIR/assert-digest-contract.sh" "$TEST_TMPDIR/digest.txt"
}

# The mandatory reasoning-leak guard line (always present per the rubric).
GUARD='Reasoning-leak guard: healthy - 0 caught, 0 missed in shipped replies.'

@test "passes a well-formed digest through unchanged" {
  run_guard $'🟢 Caroline daily · Wed Jun 4 · last 30h · 23 convs · 0 P0 / 0 P1 / 1 P2\nVoice 5 | Tools 5 | Sentiment 4\n• Sentiment: 1 frustrated\n'"$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"23 convs"* ]]
  [[ "$output" == *"Voice 5"* ]]
  [[ "$output" == *"Sentiment: 1 frustrated"* ]]
}

@test "passes a Tools-skipped digest (skipped is a valid token)" {
  run_guard $'🟢 Caroline daily · last 30h · 10 convs · 0 P0 / 0 P1 / 0 P2\nVoice 5 | Tools skipped | Sentiment 5\n'"$GUARD"
  [ "$status" -eq 0 ]
}

@test "passes a P0-day digest with the reviewer ping" {
  run_guard $'<@U0AL36NADEY> 🔴 Caroline daily · last 30h · 31 convs · 1 P0 / 2 P1 / 3 P2\nVoice 3 | Tools 4 | Sentiment 4\n*P0 leak:* 1 tool-leak line\n'"$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<@U0AL36NADEY>"* ]]
}

@test "fails loud and emits nothing when the P0/P1/P2 triplet is missing" {
  run_guard $'🟢 Caroline daily · last 30h · 23 convs\nVoice 5 | Tools 5 | Sentiment 4\n'"$GUARD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"severity triplet"* ]]
  [[ "$output" != *"Caroline daily"* ]]   # nothing passed through on failure
}

@test "fails loud when a score label is missing" {
  run_guard $'🟢 Caroline daily · last 30h · 23 convs · 0 P0 / 0 P1 / 0 P2\nVoice 5 | Sentiment 4\n'"$GUARD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tools"* ]]
}

@test "fails loud when line 2 has no scores even if later bullets mention the labels" {
  # Regression (QA review, PR #424): the score contract is line-2-specific. A
  # digest whose assembly dropped the scores line must NOT pass just because a
  # later detail bullet happens to mention Voice / Tools / Sentiment.
  run_guard $'🟢 Caroline daily · last 30h · 23 convs · 0 P0 / 0 P1 / 0 P2\n• 3 convs asked about refunds\n• Voice stayed warm, Tools were used well, Sentiment was positive\n'"$GUARD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Voice"* ]]            # complains about the missing line-2 label
  [[ "$output" != *"Caroline daily"* ]]   # nothing passed through on failure
}

@test "fails loud when the conversation count is missing" {
  run_guard $'🟢 Caroline daily · last 30h · 0 P0 / 0 P1 / 0 P2\nVoice 5 | Tools 5 | Sentiment 4\n'"$GUARD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"conversation count"* ]]
}

@test "fails loud when the reasoning-leak guard line is missing" {
  run_guard $'🟢 Caroline daily · last 30h · 23 convs · 0 P0 / 0 P1 / 0 P2\nVoice 5 | Tools 5 | Sentiment 4'
  [ "$status" -ne 0 ]
  [[ "$output" == *"guard line"* ]]
}

@test "integration: a Light-polish digest survives redact -> linkify -> assert and conv ids become links" {
  # The glanceable reformat (section emojis on line 2 + bold labels) must still satisfy
  # the contract, AND linkify-convs.sh must turn every bare conv id into a Slack link
  # while leaving the short header/score numbers alone. Exercises the real Phase-3 pipe.
  digest=$'🟢 Caroline daily · Fri Jun 5 · last 30h · 111 convs · 0 P0 / 0 P1 / 10 P2\n🎙️ Voice 5 | 🛠️ Tools skipped | 😟 Sentiment 0\n😟 *Sentiment* - 9 frustrated · conv 215474457437629 "thats a lie"\n✅ *Good catch* - conv 215474588577095 routed the cancellation\n🛡️ *Guard* - healthy: 0 caught, 0 missed in shipped replies.'
  run bash -c 'printf "%s" "$1" | "$2"/redact-output.sh | "$2"/linkify-convs.sh | "$2"/assert-digest-contract.sh' _ "$digest" "$SCRIPTS_DIR"
  [ "$status" -eq 0 ]
  # every conv id became a clickable Slack link
  [[ "$output" == *"<https://app.intercom.com/a/inboxes/all/conversations/215474457437629|215474457437629>"* ]]
  [[ "$output" == *"<https://app.intercom.com/a/inboxes/all/conversations/215474588577095|215474588577095>"* ]]
  # header contract still satisfied (emoji-prefixed score labels still match)
  [[ "$output" == *"111 convs"* ]]
  [[ "$output" == *"Voice 5"* ]]
  [[ "$output" == *"😟 Sentiment 0"* ]]
  # section emoji + bold label survived the pipeline
  [[ "$output" == *"🛡️ *Guard*"* ]]
}
