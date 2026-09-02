#!/usr/bin/env bats
# Tests for check-intercom-ops-write-doctrine.sh: the guard that keeps "the operations
# agent writes to Intercom ONLY through scripts/intercom-ops-write.sh, internal note by
# default" from silently eroding out of the ops SOUL, the muso-intercom skill, the wrapper
# itself, and the agent's skill registration.
#
# A guard that cannot fail is not a guard, so each anchor gets a removal test.
#
# Hermetic: runs against temp COPIES of the real files via the IOW_*_FILE overrides, and
# the doc scan runs against a synthetic tree via IOW_SCAN_ROOT.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-intercom-ops-write-doctrine.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  cp "$HYDRA_REPO/workspaces/operations/SOUL.md"      "$TEST_TMPDIR/ops-SOUL.md"
  cp "$HYDRA_REPO/skills-all/muso-intercom/SKILL.md"  "$TEST_TMPDIR/SKILL.md"
  cp "$HYDRA_REPO/scripts/intercom-ops-write.sh"      "$TEST_TMPDIR/wrapper.sh"
  cp "$HYDRA_REPO/openclaw-main.json"                 "$TEST_TMPDIR/openclaw-main.json"
  cp "$HYDRA_REPO/docs/lessons/muso-domain.md"        "$TEST_TMPDIR/muso-domain.md"
  cp "$HYDRA_REPO/plugins/intercom/src/sanitize-tool-leak.ts" "$TEST_TMPDIR/sanitize-tool-leak.ts"
  cp "$HYDRA_REPO/shared-reference/reference/slack-people.json" "$TEST_TMPDIR/slack-people.json"
  export IOW_LESSONS_FILE="$TEST_TMPDIR/muso-domain.md"
  export IOW_SANITIZER_FILE="$TEST_TMPDIR/sanitize-tool-leak.ts"
  export IOW_ROSTER_FILE="$TEST_TMPDIR/slack-people.json"
  export IOW_OPS_SOUL_FILE="$TEST_TMPDIR/ops-SOUL.md"
  export IOW_SKILL_FILE="$TEST_TMPDIR/SKILL.md"
  export IOW_WRAPPER_FILE="$TEST_TMPDIR/wrapper.sh"
  export IOW_MAIN_CONFIG_FILE="$TEST_TMPDIR/openclaw-main.json"
  mkdir -p "$TEST_TMPDIR/scan/skills-all/x" "$TEST_TMPDIR/scan/workspaces/operations"
  export IOW_SCAN_ROOT="$TEST_TMPDIR/scan"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# strip <file> <fixed-substring>: drop every line containing the substring.
strip() {
  grep -vF -- "$2" "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

@test "passes on the real doctrine surface" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "passes against the real repo tree as the scan root" {
  export IOW_SCAN_ROOT="$HYDRA_REPO"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- ops SOUL: the always-injected surface -----------------------------------------

@test "fails if the ops SOUL stops naming the wrapper" {
  strip "$TEST_TMPDIR/ops-SOUL.md" "intercom-ops-write.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"operations/SOUL.md"* ]]
}

@test "fails if the ops SOUL loses note-by-default" {
  strip "$TEST_TMPDIR/ops-SOUL.md" "internal note by default"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails if the ops SOUL loses the note header convention" {
  strip "$TEST_TMPDIR/ops-SOUL.md" "Note to"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

# --- the skill ---------------------------------------------------------------------

@test "fails if the skill stops routing writes to the wrapper" {
  strip "$TEST_TMPDIR/SKILL.md" "intercom-ops-write.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"muso-intercom/SKILL.md"* ]]
}

@test "fails if the skill loses the no-raw-curl prohibition" {
  strip "$TEST_TMPDIR/SKILL.md" "never a raw curl"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails if a skill doc teaches a raw Intercom write" {
  cat > "$TEST_TMPDIR/scan/skills-all/x/SKILL.md" <<'MD'
# Some skill
curl -s -X POST -d '{"message_type":"comment","type":"admin","admin_id":"5763097","body":"hi"}' \
  "https://api.intercom.io/conversations/CONVERSATION_ID/reply"
MD
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills-all/x/SKILL.md"* ]]
}

@test "fails if a workspace doc carries the reply endpoint even without message_type" {
  cat > "$TEST_TMPDIR/scan/workspaces/operations/NOTES.md" <<'MD'
POST https://api.intercom.io/conversations/123/reply with a body
MD
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "a doc that only reads conversations is fine" {
  cat > "$TEST_TMPDIR/scan/skills-all/x/SKILL.md" <<'MD'
curl -s "https://api.intercom.io/conversations/CONVERSATION_ID?display_as=plaintext" | jq
Notes are internal; a reply reaches the customer. Use intercom-ops-write.sh for either.
MD
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- the wrapper: the pins that make the doctrine mechanical ------------------------

@test "fails if the wrapper is committed in test mode" {
  sed -i.bak 's/^readonly TESTABLE=0$/readonly TESTABLE=1/' "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TESTABLE"* ]]
}

@test "fails if a second TESTABLE assignment is appended" {
  printf '\nTESTABLE=$((1))\n' >> "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TESTABLE"* ]]
}

@test "fails if the wrapper's posting identity is not Caroline" {
  sed -i.bak 's/^readonly INTERCOM_ADMIN_ID="5763097"$/readonly INTERCOM_ADMIN_ID="10206197"/' "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"5763097"* ]]
}

@test "fails if the wrapper's endpoint is no longer pinned to api.intercom.io" {
  sed -i.bak 's#^readonly API_BASE="https://api.intercom.io"$#readonly API_BASE="${INTERCOM_API_BASE:-https://api.intercom.io}"#' "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"API_BASE"* ]]
}

@test "fails if the wrapper drops the privileged absolute shebang or the PATH reset" {
  sed -i.bak '1s|.*|#!/usr/bin/env bash|' "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#!/bin/bash -p"* ]]
}

# --- the leak-word list is anchored on the plugin's PATTERNS array --------------------

@test "fails if the wrapper drops a pattern the sanitizer still redacts" {
  sed -i.bak 's/^readonly SANITIZER_WORDS="profile_status|/readonly SANITIZER_WORDS="/' "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SANITIZER_WORDS differs"* ]]
  [[ "$output" == *"profile_status"* ]]
}

@test "fails if the sanitizer gains a pattern the wrapper does not refuse" {
  # awk, not sed: BSD sed does not expand \n in a replacement, and a no-op mutation here
  # would pass for the wrong reason.
  awk '{print} /^const PATTERNS: RegExp\[\] = \[$/ {print "  /\\bbackend_probe\\b/g,"}' \
    "$TEST_TMPDIR/sanitize-tool-leak.ts" > "$TEST_TMPDIR/ts.tmp" && mv "$TEST_TMPDIR/ts.tmp" "$TEST_TMPDIR/sanitize-tool-leak.ts"
  grep -q '/\\bbackend_probe\\b/g,' "$TEST_TMPDIR/sanitize-tool-leak.ts"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"backend_probe"* ]]
}

@test "fails if the sanitizer loses its patterns entirely" {
  strip "$TEST_TMPDIR/sanitize-tool-leak.ts" '/\b'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PATTERNS"* ]]
}

@test "the wrapper does not refuse the prose-only voice words the sanitizer never redacts" {
  # docs/lessons/muso-domain.md once listed error/system/API as sanitizer words; they are not.
  # `run` + status, not `! grep`: a negated command in a bats loop is a set -e no-op.
  for w in tool lookup error unavailable system API; do
    run grep -qE "^readonly SANITIZER_WORDS=\"([^\"]*\|)?$w(\|[^\"]*)?\"$" "$HYDRA_REPO/scripts/intercom-ops-write.sh"
    [ "$status" -ne 0 ]
  done
}

# --- the write allowlist is pinned to the skill prose and the roster ------------------

@test "fails if the skill's Write Access Control drops a human the wrapper still allowlists" {
  sed -i.bak 's/`U038BM16T7W` (Jan), //' "$TEST_TMPDIR/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Write Access Control"* ]]
}

@test "fails if the wrapper allowlists a human the skill does not" {
  awk '{print} /^    U0AL36NADEY\) echo "Nick" ;;$/ {print "    U0AAAAAAAAA) echo \"Zed\" ;;"}' \
    "$TEST_TMPDIR/wrapper.sh" > "$TEST_TMPDIR/w.tmp" && mv "$TEST_TMPDIR/w.tmp" "$TEST_TMPDIR/wrapper.sh"
  grep -q 'U0AAAAAAAAA) echo "Zed"' "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"U0AAAAAAAAA"* ]]
}

@test "fails if a wrapper arm names someone the roster does not list as a current human under that name" {
  sed -i.bak 's/^    U038BM16T7W) echo "Jan" ;;$/    U038BM16T7W) echo "Jam" ;;/' "$TEST_TMPDIR/wrapper.sh"
  grep -q '"Jam"' "$TEST_TMPDIR/wrapper.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"slack-people.json"* ]]
  [[ "$output" == *"Jam"* ]]
}

@test "the gate FAILS when jq is unavailable: it cannot certify what it cannot check" {
  # Same control as check-agent-bridge-doctrine.bats (PR #877): "could not run" and
  # "passed" must never share exit 0.
  stub_bin="$TEST_TMPDIR/nojq"
  mkdir -p "$stub_bin"
  for c in grep sed awk cat cut tr sort comm head tail basename dirname printf env bash date wc mktemp rm find; do
    p="$(command -v $c || true)"; [ -n "$p" ] && ln -sf "$p" "$stub_bin/$c"
  done
  run env PATH="$stub_bin" "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]]
  [[ "$output" != *"OK:"* ]]
}

# --- registration ------------------------------------------------------------------

@test "fails if muso-intercom is unregistered from the operations agent" {
  jq '(.agents.list[] | select(.id=="operations") | .skills) |= map(select(. != "muso-intercom"))' \
    "$TEST_TMPDIR/openclaw-main.json" > "$TEST_TMPDIR/cfg.tmp"
  mv "$TEST_TMPDIR/cfg.tmp" "$TEST_TMPDIR/openclaw-main.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"muso-intercom"* ]]
}
