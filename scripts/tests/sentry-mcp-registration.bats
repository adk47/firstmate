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
       grab {print; if ($0 ~ /^echo "registered/) exit}' "$DOC" > "$BLOCK"
  # `[ -s ]` alone is NOT enough, and that is not hypothetical: when the runbook's
  # closing line changed from `echo "registered and scoped...` to
  # `echo "registered (unscoped by design)...` on 2026-09-10, awk never hit its
  # terminator, grabbed the whole REST of the runbook as "the block", and every
  # case here failed for a reason none of them named. Assert the extraction
  # actually STOPPED where it was meant to, and fail loud (not `fail`, which is a
  # bats-assert helper this suite does not load — calling it yields a bare 127).
  if [ ! -s "$BLOCK" ] || ! tail -n 1 "$BLOCK" | grep -q '^echo "registered'; then
    echo "could not extract the registration block from $DOC — the terminator" >&2
    echo "line (^echo \"registered) is gone or moved; fix this awk, do not skip." >&2
    return 1
  fi

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

@test "the block registers the server and adds NO deny to any agent" {
  # INVERTED 2026-09-10. This recipe used to add `sentry__*` to every non-cto/qa
  # agent in the same atomic write. On openclaw >= 2026.8 that deny fails
  # isKnownCoreToolId, marks the agent's policy restricted, and silently strips
  # its entire codex native tool surface (web search, shell, images, browser,
  # skill search, memories). See validate-config-matrix.sh check #8.
  run run_block "tok-abc123"
  [ "$status" -eq 0 ]
  run jq -r '.mcp.servers.sentry.url' "$CFG"
  [ "$output" = "https://mcp.sentry.dev/mcp" ]
  run jq -r '[.agents.list[] | (.tools.deny // [])[]
             | select(startswith("sentry__"))] | length' "$CFG"
  [ "$output" = "0" ]
}

@test "the block ABORTS if a pre-2026.8 sentry deny is still in the config" {
  # Its own validation must fail closed on a leftover deny, so a config carrying
  # one is never announced, renamed and hot-reloaded as if it were healthy.
  jq '(.agents.list[] | select(.id=="clio") | .tools.deny) = ["sentry__*"]' \
     "$CFG" > "$CFG.new" && mv "$CFG.new" "$CFG"
  cp "$CFG" "$BATS_TEST_TMPDIR/original.json"
  run run_block "tok-abc123"
  [ "$status" -ne 0 ]
  run diff -q "$CFG" "$BATS_TEST_TMPDIR/original.json"
  [ "$status" -eq 0 ]
}

@test "pre-existing non-sentry denies are preserved, not replaced" {
  run run_block "tok-abc123"
  [ "$status" -eq 0 ]
  run jq -r '.agents.list[] | select(.id=="operations") | .tools.deny | sort | @csv' "$CFG"
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

# ---- deny-list reconciliation: RETIRED 2026-09-10 --------------------------
# Nine cases used to live here, extracting the runbook's "Enumerate from the
# CONNECTED catalog" block and proving the `sentry__*` deny COVERED every
# registered tool. That block is gone: on openclaw >= 2026.8 the deny is not a
# scoping mechanism, it is a kill switch for the agent's whole codex native tool
# surface, so there is no deny list left to reconcile. Deleted rather than
# skipped -- a suite that silently skips what it can no longer extract is the
# false green those cases existed to prevent. The surviving invariant ("no
# sentry deny may reappear in a committed config") is pinned by
# scripts/tests/sentry-mcp-scoping.bats and validate-config-matrix.sh check #8.

@test "the runbook REFUSES while the MCP is disabled (QA #929 v3 finding 3)" {
  # An operator following the recipe would hot-reload an unscoped Sentry server
  # into a fleet where every agent can reach sentry__update_issue — and the
  # healer would tear it out on the next start anyway. The section must carry a
  # stop-gate naming the real control, not a parallel live write.
  local rb; rb="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/docs/runbooks/RUNBOOK.md"
  [ -r "$rb" ]
  run sed -n '/^### Register the Sentry MCP server$/,/^```bash$/p' "$rb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STOP"* ]]
  [[ "$output" == *"ESM_ENABLED"* ]]
  [[ "$output" == *"will NOT stick"* ]]
}
