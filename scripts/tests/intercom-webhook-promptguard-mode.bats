#!/usr/bin/env bats
# The webhook's PrompGuard mode gate. Not cosmetic: `PROMPTGUARD_MODE` decides whether a detected
# injection is acted on or only logged, so an unrecognised value that silently means "shadow" would
# switch enforcement off without anyone noticing. Raised in review of #1719.
#
# These tests drive the resolver directly (the intake module itself refuses to boot without the
# Intercom credentials, so booting it is not an option here).

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  MODULE="$ROOT/scripts/intercom-webhook-promptguard-mode.js"
  WEBHOOK="$ROOT/scripts/intercom-webhook.js"
}

resolve() {
  # Prints "<mode>|<enforcing>|<valid>" for the given raw value ("__UNSET__" means undefined).
  if [ "$1" = "__UNSET__" ]; then
    node -e 'const r=require(process.argv[1]).resolvePromptguardMode(undefined);console.log([r.mode,r.enforcing,r.valid].join("|"))' "$MODULE"
  else
    node -e 'const r=require(process.argv[1]).resolvePromptguardMode(process.argv[2]);console.log([r.mode,r.enforcing,r.valid].join("|"))' "$MODULE" "$1"
  fi
}

@test "unset and empty default to shadow (the measurement window is the default)" {
  [ "$(resolve "__UNSET__")" = "shadow|false|true" ]
  [ "$(resolve "")" = "shadow|false|true" ]
  [ "$(resolve "   ")" = "shadow|false|true" ]
}

@test "shadow and enforce are honoured, case- and whitespace-insensitively" {
  [ "$(resolve "shadow")" = "shadow|false|true" ]
  [ "$(resolve "enforce")" = "enforce|true|true" ]
  [ "$(resolve "ENFORCE")" = "enforce|true|true" ]
  [ "$(resolve "  Enforce ")" = "enforce|true|true" ]
}

@test "a typo'd mode ENFORCES instead of silently disabling the block" {
  # The whole point: the operator believed this was enforcing.
  [ "$(resolve "enfroce")" = "enforce|true|false" ]
  [ "$(resolve "enforced")" = "enforce|true|false" ]
  [ "$(resolve "true")" = "enforce|true|false" ]
}

@test "an unrecognised mode names the raw value in a warning, so the typo is loud" {
  run node -e 'const r=require(process.argv[1]).resolvePromptguardMode(process.argv[2]);console.log(String(r.warning))' "$MODULE" "enfroce"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"enfroce"'* ]]
  [[ "$output" == *"shadow|enforce"* ]] || [[ "$output" == *"is not one of"* ]]
}

@test "the webhook uses the resolver rather than its own copy of the rule" {
  run grep -F 'require("./intercom-webhook-promptguard-mode.js")' "$WEBHOOK"
  [ "$status" -eq 0 ]
  run grep -F "resolvePromptguardMode(process.env.PROMPTGUARD_MODE)" "$WEBHOOK"
  [ "$status" -eq 0 ]
  # A second, independent definition of the rule would be the drift this test exists to stop.
  run bash -c "grep -cE 'PROMPTGUARD_MODE *=.*(toLowerCase|===)' '$WEBHOOK' || true"
  [ "$output" = "0" ]
}
