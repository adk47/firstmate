#!/usr/bin/env bats
# The Sentry MCP registration block in RUNBOOK.md, exercised as written.
#
# This block had no coverage and shipped three defects in a row: it once
# truncated the live config to zero bytes on a jq failure, once validated and
# then never announced or renamed at all, and once wrote an empty
# "Sentry-Bearer " header because `read` makes a shell variable while jq's
# `env.` sees only exported ones. Prose review missed all three; running it
# catches them.
#
# The block is extracted from the runbook at run time so this tracks the
# documented procedure rather than a copy that can drift.

setup() {
  HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  DOC="$HYDRA_REPO/docs/runbooks/RUNBOOK.md"
  [ -f "$DOC" ] || skip "runbook not found"

  BLOCK="$BATS_TEST_TMPDIR/register.sh"
  awk '/^cfg=\/root\/\.openclaw-main\/openclaw\.json$/ {grab=1}
       grab {print; if ($0 ~ /^echo "registered and scoped/) exit}' "$DOC" > "$BLOCK"
  [ -s "$BLOCK" ] || fail "could not extract the registration block"

  # a realistic config: agents live at .agents.list, one already has denies
  CFG="$BATS_TEST_TMPDIR/openclaw.json"
  cat > "$CFG" <<'JSON'
{"agents":{"defaults":{},"list":[
  {"id":"clio"},{"id":"cto"},{"id":"qa"},
  {"id":"operations","tools":{"deny":["web_search","web_fetch"]}}]}}
JSON
  cp "$CFG" "$BATS_TEST_TMPDIR/original.json"

  # stub the announce script the block calls
  mkdir -p "$BATS_TEST_TMPDIR/opt/hydra/scripts/lib"
  ANNOUNCE="$BATS_TEST_TMPDIR/opt/hydra/scripts/lib/announce-legit-write.sh"
  printf '#!/bin/sh\ntouch "%s/announced"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$ANNOUNCE"
  chmod +x "$ANNOUNCE"

  # point the block at the fixtures, and feed the token on stdin like a prompt
  sed -i.bak \
    -e "s|/root/.openclaw-main/openclaw.json|$CFG|" \
    -e "s|/opt/hydra/scripts/lib/announce-legit-write.sh|$ANNOUNCE|" \
    "$BLOCK"
}

run_block() { printf '%s\n' "$1" | bash "$BLOCK"; }

@test "a real token is written into the Authorization header" {
  run run_block "tok-abc123"
  [ "$status" -eq 0 ]
  run jq -r '.mcp.servers.sentry.headers.Authorization' "$CFG"
  [ "$output" = "Sentry-Bearer tok-abc123" ]
}

@test "REGRESSION: the token must survive into jq (read makes a NON-exported var)" {
  # Without `SENTRY_TOKEN=... jq`, env.SENTRY_TOKEN is empty and the header is
  # written as the bare prefix -- then announced, renamed and restarted, leaving
  # every Sentry request failing auth.
  run run_block "tok-abc123"
  [ "$status" -eq 0 ]
  run jq -r '.mcp.servers.sentry.headers.Authorization' "$CFG"
  [ "$output" != "Sentry-Bearer " ]
  [[ "$output" == "Sentry-Bearer tok-abc123" ]]
}

@test "an empty token is refused and the live config is untouched" {
  run run_block ""
  [ "$status" -ne 0 ]
  run diff -q "$CFG" "$BATS_TEST_TMPDIR/original.json"
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/announced" ]
}

@test "registration and scoping land in ONE write: server + denies together" {
  run run_block "tok-abc123"
  [ "$status" -eq 0 ]
  run jq -r '[.agents.list[] | select(.id!="cto" and .id!="qa")
             | ((.tools.deny // []) | map(select(startswith("sentry__"))) | length)] | unique | @csv' "$CFG"
  [ "$output" = "9" ]
  run jq -r '[.agents.list[] | select(.id=="cto" or .id=="qa")
             | ((.tools.deny // []) | map(select(startswith("sentry__"))) | length)] | add' "$CFG"
  [ "$output" = "0" ]
}

@test "pre-existing denies are preserved, not replaced" {
  run run_block "tok-abc123"
  [ "$status" -eq 0 ]
  run jq -r '.agents.list[] | select(.id=="operations") | .tools.deny
             | map(select(startswith("sentry__")|not)) | sort | @csv' "$CFG"
  [ "$output" = '"web_fetch","web_search"' ]
}

@test "a malformed config aborts without truncating the live file" {
  echo '{ not json' > "$CFG"
  cp "$CFG" "$BATS_TEST_TMPDIR/original.json"
  run run_block "tok-abc123"
  [ "$status" -ne 0 ]
  [ -s "$CFG" ]
  run diff -q "$CFG" "$BATS_TEST_TMPDIR/original.json"
  [ "$status" -eq 0 ]
}

@test "a failed announce leaves the live config unchanged and no temp file behind" {
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/opt/hydra/scripts/lib/announce-legit-write.sh"
  chmod +x "$BATS_TEST_TMPDIR/opt/hydra/scripts/lib/announce-legit-write.sh"
  run run_block "tok-abc123"
  [ "$status" -ne 0 ]
  run diff -q "$CFG" "$BATS_TEST_TMPDIR/original.json"
  [ "$status" -eq 0 ]
  # the temp file holds the TOKEN and must not be left on disk
  run bash -c "ls $(dirname "$CFG")/tmp.* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}
