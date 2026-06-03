#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }
teardown() { teardown_skill_tmp; }

@test "scrubs email reintroduced by LLM in summary text" {
  text='Top frustration: conv-123 — "you should email alice@example.com to fix this"'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" != *"alice@example.com"* ]]
  [[ "$result" == *"<email>"* ]]
}

@test "scrubs phone number" {
  text='customer left phone +1 555 123 4567 in message'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" != *"555 123 4567"* ]]
  [[ "$result" == *"<phone>"* ]]
}

@test "scrubs Stripe customer/payment/charge ids" {
  text='cus_ABC123 pi_xyz_789 ch_FOO456'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" != *"cus_ABC123"* ]]
  [[ "$result" != *"pi_xyz_789"* ]]
  [[ "$result" != *"ch_FOO456"* ]]
  [[ "$result" == *"<stripe_id>"* ]]
}

@test "preserves conversation_id and contact_id" {
  text='conv-abc-123 contact-xyz-789'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" == *"conv-abc-123"* ]]
  [[ "$result" == *"contact-xyz-789"* ]]
}

@test "preserves Slack mention syntax" {
  text='<@U0AL36NADEY> — review'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" == *"<@U0AL36NADEY>"* ]]
}

@test "preserves YYYY-MM-DD dates (regression: phone regex was over-matching)" {
  text='week of 2026-05-14 had 3 issues'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" == *"2026-05-14"* ]]
  [[ "$result" != *"<phone>"* ]]
}

@test "preserves short numeric ids (PR numbers, ticket ids)" {
  text='PR #1234567 closed; ticket 9876543'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" == *"1234567"* ]]
  [[ "$result" == *"9876543"* ]]
  [[ "$result" != *"<phone>"* ]]
}

@test "preserves 15-16 digit numeric Intercom conversation ids (regression: phone over-matched)" {
  # The weekly report cites conversation ids as the evidence pointers users
  # investigate. The unfenced phone regex rewrote a real id like 215474545718046
  # to <phone>46, destroying the citation. The digit-fenced regex must leave a
  # long numeric id intact while still scrubbing a real phone alongside it.
  text='Repeated FLAC question (conv 215474545718046, conv 998877665544001) — call 555-123-4567 to follow up'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" == *"215474545718046"* ]]
  [[ "$result" == *"998877665544001"* ]]
  # the real phone is still scrubbed
  [[ "$result" != *"555-123-4567"* ]]
  [[ "$result" == *"<phone>"* ]]
}

@test "normalizes em/en dashes so the final review has no em-dashes (voice rule)" {
  text='Caroline weekly review — week of 2026-06-01; FLAC–export gap'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" != *"—"* ]]
  [[ "$result" != *"–"* ]]
  [[ "$result" == *"review - week"* ]]
}

@test "still scrubs canonical phone formats" {
  for input in "+1 555 123 4567" "(555) 123-4567" "555-123-4567" "5551234567"; do
    result=$(printf '%s' "$input" | "$SCRIPTS_DIR/redact-output.sh")
    [[ "$result" == *"<phone>"* ]] || { echo "Failed to scrub: $input -> $result" >&2; return 1; }
  done
}
