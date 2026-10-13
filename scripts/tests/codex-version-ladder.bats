#!/usr/bin/env bats
# codex-version.sh runtime-aware ladder (MUS-5079). The codex plugin pin must
# follow the runtime it will serve: an 8.2 box must not be handed the 8.35 plugin.

_pin() {
  env -u OPENCLAW_CODEX_VERSION OPENCLAW_VERSION="$1" bash -c \
    "source '$BATS_TEST_DIRNAME/../lib/codex-version.sh'; printf %s \"\$OPENCLAW_CODEX_VERSION\""
}

@test "runtime 2026.8.35 pins codex 2026.8.35" {
  [ "$(_pin 2026.8.35)" = "2026.8.35" ]
}

@test "a runtime newer than 2026.8.35 still pins 2026.8.35" {
  [ "$(_pin 2026.9.9)" = "2026.8.35" ]
}

@test "runtime 2026.8.2 stays on codex 2026.8.2 (merge->upgrade hazard window)" {
  [ "$(_pin 2026.8.2)" = "2026.8.2" ]
}

@test "runtime 2026.7.1 pins codex 2026.7.1" {
  [ "$(_pin 2026.7.1)" = "2026.7.1" ]
}

@test "runtime 2026.6.1 holds codex 2026.5.27" {
  [ "$(_pin 2026.6.1)" = "2026.5.27" ]
}

@test "deploy.sh default OPENCLAW_VERSION resolves to the 8.35 pin" {
  v=$(grep '^OPENCLAW_VERSION=' "$BATS_TEST_DIRNAME/../deploy.sh" | sed -E 's/.*-([0-9.]+)\}.*/\1/')
  [ "$v" = "2026.8.35" ]
  [ "$(_pin "$v")" = "2026.8.35" ]
}
