#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }
teardown() { teardown_skill_tmp; }

# linkify-convs.sh turns every bare 15-16 digit Intercom conversation id into a
# clickable Slack mrkdwn link, deterministically, so the digest's links never depend
# on the LLM emitting <url|label> syntax. Runs AFTER redact-output.sh, BEFORE
# assert-digest-contract.sh. URL pattern mirrors check-escalated.sh.

@test "wraps a bare conversation id into a Slack mrkdwn link" {
  result=$(printf '%s' 'Sentiment: conv 215474457437629 frustrated' | "$SCRIPTS_DIR/linkify-convs.sh")
  [[ "$result" == *"<https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/215474457437629|215474457437629>"* ]]
}

@test "wraps EVERY id in a comma list and preserves the (count) suffixes" {
  result=$(printf '%s' 'Top: 215474587591607(17), 215474538593051(14), 215474580690567(13)' | "$SCRIPTS_DIR/linkify-convs.sh")
  [[ "$result" == *"conversation/215474587591607|215474587591607>(17)"* ]]
  [[ "$result" == *"conversation/215474538593051|215474538593051>(14)"* ]]
  [[ "$result" == *"conversation/215474580690567|215474580690567>(13)"* ]]
}

@test "wraps two ids separated by a single space (adjacent; lookarounds handle it)" {
  result=$(printf '%s' '215474457437629 998877665544001' | "$SCRIPTS_DIR/linkify-convs.sh")
  [[ "$result" == *"conversation/215474457437629|215474457437629> <https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/998877665544001|998877665544001>"* ]]
}

@test "leaves the header/scores line (short numbers) untouched" {
  text='Caroline daily - Fri Jun 5 - last 30h - 111 convs - 0 P0 / 0 P1 / 10 P2'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/linkify-convs.sh")
  [ "$result" = "$text" ]
}

@test "does NOT re-wrap an id already inside a conversations URL (guards a hand-written URL)" {
  text='see https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/215474457437629 now'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/linkify-convs.sh")
  [ "$result" = "$text" ]
}

@test "is idempotent (piping the output through again == running once)" {
  text='conv 215474457437629 and 998877665544001(3)'
  once=$(printf '%s' "$text" | "$SCRIPTS_DIR/linkify-convs.sh")
  twice=$(printf '%s' "$once" | "$SCRIPTS_DIR/linkify-convs.sh")
  [ "$once" = "$twice" ]
}

@test "passes text with no conversation ids through unchanged" {
  text='Reasoning-leak guard: healthy - 0 caught, 0 missed in shipped replies.'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/linkify-convs.sh")
  [ "$result" = "$text" ]
}

@test "does not wrap a 14-or-fewer or 17-or-more digit run (only real conv ids)" {
  # 14 digits (too short) and 17 digits (too long) must be left alone.
  result=$(printf '%s' 'x 12345678901234 y 12345678901234567 z' | "$SCRIPTS_DIR/linkify-convs.sh")
  [ "$result" = 'x 12345678901234 y 12345678901234567 z' ]
}

@test "INTERCOM_WORKSPACE_ID overrides the workspace in the deep-link" {
  result=$(printf '%s' '215474457437629' | INTERCOM_WORKSPACE_ID=zzzz "$SCRIPTS_DIR/linkify-convs.sh")
  [[ "$result" == *"<https://app.intercom.com/a/inbox/zzzz/inbox/conversation/215474457437629|215474457437629>"* ]]
}
