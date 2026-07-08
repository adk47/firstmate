#!/usr/bin/env bats
# Guard the LLM classifier doctrine for cases that should be Caroline-owned
# even when the eventual action is a ticket or human-executed write.

SKILL="${BATS_TEST_DIRNAME}/../../SKILL.md"

@test "account/profile deletion intake is classified as Caroline-owned first contact" {
  run grep -qi "account/profile deletion" "$SKILL"
  [ "$status" -eq 0 ]

  run grep -qi "removal intake for the customer's own Muso account/profile" "$SKILL"
  [ "$status" -eq 0 ]

  human_block="$(awk '/- `human`/{flag=1} flag{print} /- `spam`/{flag=0}' "$SKILL")"
  [[ "$human_block" != *"irreversible account/profile deletion"* ]]
}
