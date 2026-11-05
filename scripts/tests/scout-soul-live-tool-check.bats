#!/usr/bin/env bats
# Scout's SOUL must stop it reporting a tool unavailable from history or memory (MUS-29978).
# 2026-11-05: McLaren was told search was unavailable at 12:21Z; Scout had read a 4 Nov note
# ("web_search has no provider"), made zero searches, and passed the stale note on. Search was
# working. The doctrine must make one live call the test for "unavailable", not a note.
# Scope: the `## Tool Permissions` section of workspaces/scout/SOUL.md only.
bats_require_minimum_version 1.5.0

REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SOUL="$REPO/workspaces/scout/SOUL.md"

setup() {
  SECTION="$BATS_TEST_TMPDIR/tool-permissions.md"
  awk '/^## Tool Permissions/{f=1;next} /^## /{f=0} f' "$SOUL" > "$SECTION"
}

@test "Tool Permissions forbids reporting a tool unavailable because history or memory says so" {
  # Non-empty guard: an empty extraction must not pass a negative-style check.
  [ -s "$SECTION" ] || { echo "Tool Permissions section not found in $SOUL" >&3; return 1; }
  run grep -iE 'unavailable.*(history|memory)|(history|memory).*unavailable' "$SECTION"
  if [ "$status" -ne 0 ]; then
    echo "no line in ## Tool Permissions forbids calling a tool unavailable from history/memory" >&3
    return 1
  fi
}

@test "Tool Permissions requires one live tool call before any availability claim" {
  [ -s "$SECTION" ] || { echo "Tool Permissions section not found in $SOUL" >&3; return 1; }
  run grep -iE 'live (call|check)|call the tool (once )?now' "$SECTION"
  if [ "$status" -ne 0 ]; then
    echo "no line in ## Tool Permissions requires a live tool call first" >&3
    return 1
  fi
}

@test "live-call rule exempts Denied tools and policy denials, on the same line" {
  # The live-call rule must not force Scout to probe a tool it is denied (QA finding, MUS-29978
  # round 1). Both halves must sit on one line: a 'denied' word elsewhere in the section proves nothing.
  [ -s "$SECTION" ] || { echo "Tool Permissions section not found in $SOUL" >&3; return 1; }
  run grep -iE 'live (call|check).*denied|denied.*live (call|check)' "$SECTION"
  if [ "$status" -ne 0 ]; then
    echo "no line in ## Tool Permissions exempts Denied tools from the live-call rule" >&3
    return 1
  fi
}
