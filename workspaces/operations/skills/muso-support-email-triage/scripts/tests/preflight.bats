#!/usr/bin/env bats
# preflight.sh: the shared support@ Gmail kill file stops the run before any gog call (firstmate 10-31).

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  # a gog that records every call: the kill file must stop preflight before the first one
  printf '#!/usr/bin/env bash\necho "$@" >> "%s/gog.calls"\necho '"'"'{"accounts":[{"email":"support@muso.ai"}]}'"'"'\n' "$TMP" > "$TMP/bin/gog"
  chmod +x "$TMP/bin/gog"
  export PATH="$TMP/bin:$PATH"
  # the kill path is a constant in preflight.sh (no env override): test a COPY with only that path rewritten
  KILL="$TMP/gmail-readers.disabled"
  sed "s#^GMAIL_READERS_KILL=\"/etc/hydra/gmail-readers.disabled\"#GMAIL_READERS_KILL=\"$KILL\"#" \
    "$DIR/preflight.sh" > "$TMP/preflight.sh"
  grep -q "^GMAIL_READERS_KILL=\"$KILL\"" "$TMP/preflight.sh"
}

teardown() { rm -rf "$TMP"; }

@test "the kill file stops preflight before any gog call" {
  touch "$KILL"
  run bash "$TMP/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"preflight failed: support@ Gmail readers disabled"* ]]
  [ ! -e "$TMP/gog.calls" ]
}

@test "the kill path cannot be moved by the environment" {
  HYDRA_GMAIL_READERS_KILL="$TMP/elsewhere" run bash -c 'grep -c HYDRA_GMAIL_READERS_KILL "$1"' _ "$DIR/preflight.sh"
  [ "$output" = "0" ]
}

@test "without the kill file preflight proceeds to the gog auth check" {
  run bash "$TMP/preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight: ok"* ]]
  grep -q "auth list" "$TMP/gog.calls"
}
