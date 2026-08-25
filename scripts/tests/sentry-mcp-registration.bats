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

# ---- deny-list reconciliation against the PROBED catalog -------------------
# `mcp list --json` has no .tools[] (it returns the configured definitions), and
# a journal grep only proves SOME id appeared recently -- if the window mentions
# one tool, a naive check reports "reconciled" while the rest stay un-denied.
# These cases pin that the enumeration comes from `mcp probe` and fails closed.

setup_reconcile() {
  RCFG="$BATS_TEST_TMPDIR/rcfg.json"
  cat > "$RCFG" <<'JSON'
{"agents":{"list":[{"id":"cto"},{"id":"qa"},
 {"id":"cmo","tools":{"deny":["sentry__search_issues","sentry__find_projects"]}},
 {"id":"scout","tools":{"deny":["sentry__search_issues","sentry__find_projects","sentry__get_trace_details"]}}]}}
JSON
  RECON="$BATS_TEST_TMPDIR/recon.sh"
  awk '/^# Enumerate from the CONNECTED catalog/ {grab=1}
       grab {print; if ($0 ~ /^echo "scoping reconciled/) exit}'     "$HYDRA_REPO/docs/runbooks/RUNBOOK.md" > "$RECON"
  [ -s "$RECON" ] || fail "could not extract the reconciliation block"
  sed -i.bak '/^openclaw --profile main mcp list | grep -i sentry$/d' "$RECON"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
}

# $1 = JSON that the stubbed `openclaw mcp probe` should emit
stub_probe() {
  printf '#!/bin/sh
cat <<'"'"'P'"'"'
%s
P
exit 0
' "$1" > "$BATS_TEST_TMPDIR/bin/openclaw"
  chmod +x "$BATS_TEST_TMPDIR/bin/openclaw"
}

@test "reconcile: ALL probed tool ids are enumerated, not just one" {
  setup_reconcile
  stub_probe '{"tools":[{"name":"search_issues"},{"name":"find_projects"},{"name":"get_trace_details"},{"name":"execute_sentry_tool"}]}'
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" cfg="$RCFG" bash "$RECON"
  [ "$status" -ne 0 ]                       # cmo is missing two of them
  [[ "$output" == *"probed catalog (4 tools)"* ]]
  [[ "$output" == *"GAP cmo"* ]]
  [[ "$output" == *"sentry__get_trace_details"* ]]
  [[ "$output" == *"sentry__execute_sentry_tool"* ]]
}

@test "reconcile: passes only when every agent denies every probed id" {
  setup_reconcile
  stub_probe '{"tools":[{"name":"search_issues"},{"name":"find_projects"}]}'
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" cfg="$RCFG" bash "$RECON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scoping reconciled against the probed catalog"* ]]
}

@test "reconcile: an EMPTY probe refuses instead of reporting success" {
  # probe exits 0 with tools:[] when nothing is reachable, so rc is not the gate
  setup_reconcile
  stub_probe '{"generatedAt":"x","servers":{},"tools":[],"diagnostics":[]}'
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" cfg="$RCFG" bash "$RECON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"catalog is unproven"* ]]
  [[ "$output" != *"reconciled"* ]]
}

@test "reconcile: a failing probe refuses" {
  setup_reconcile
  printf '#!/bin/sh
exit 1
' > "$BATS_TEST_TMPDIR/bin/openclaw"
  chmod +x "$BATS_TEST_TMPDIR/bin/openclaw"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" cfg="$RCFG" bash "$RECON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mcp probe failed"* ]]
  [[ "$output" != *"reconciled"* ]]
}

@test "reconcile: an unreadable config refuses instead of a vacuous pass" {
  # `for agent in $(jq ...)` fails OPEN: a broken cfg yields no loop items, gap
  # stays 0, and the block would report "reconciled" having checked no agent.
  setup_reconcile
  stub_probe '{"tools":[{"name":"search_issues"}]}'
  echo '{ not valid json' > "$RCFG"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" cfg="$RCFG" bash "$RECON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"scoping is UNVERIFIED"* ]]
  [[ "$output" != *"reconciled"* ]]
}

@test "reconcile: a config with no .agents.list refuses" {
  setup_reconcile
  stub_probe '{"tools":[{"name":"search_issues"}]}'
  echo '{"agents":{"defaults":{}}}' > "$RCFG"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" cfg="$RCFG" bash "$RECON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"scoping is UNVERIFIED"* ]]
  [[ "$output" != *"reconciled"* ]]
}

@test "reconcile: a cto/qa-only fleet refuses a vacuous pass" {
  # nothing to check is not the same as everything checked
  setup_reconcile
  stub_probe '{"tools":[{"name":"search_issues"}]}'
  echo '{"agents":{"list":[{"id":"cto"},{"id":"qa"}]}}' > "$RCFG"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" cfg="$RCFG" bash "$RECON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"vacuous pass"* ]]
  [[ "$output" != *"reconciled"* ]]
}
