#!/usr/bin/env bats
#
# scripts/rollback.sh — .mcp.servers must survive a rollback.
#
# REGRESSION THIS SUITE EXISTS FOR (2026-08-26, deploy run 32933062895):
# attempt 1 of that deploy failed, deploy.yml's `Rollback on failure` step fired
# rollback.sh, and rollback.sh restored the profile configs with a plain
#     cp "$PROFILE_SRC_ROOT/openclaw-main.json" "$dst"
# The forward path (deploy.sh sync_profile_config) carefully PRESERVES
# `.mcp.servers` from the live file, because that is where server-side
# registrations live and they carry auth tokens that are deliberately not
# committed. The rollback path did not. Result: the Sentry MCP server -- and any
# other runtime registration on either profile -- was destroyed, silently, by a
# deploy that GitHub reported as "success" (only attempt 2 succeeded, and
# `gh run list` shows just the latest attempt).
#
# The audit trail that proved it, /var/log/openclaw-legitimate-writes.log:
#   ...04:40:49Z deploy.sh ...   -> "preserved 1 live MCP server(s)"
#   ...05:11:15Z rollback  ...   -> the entry is gone
#   ...06:14:32Z deploy.sh ...   -> "preserved 0"
#
# ROLLBACK_SH points the suite at a different implementation so a reviewer can
# confirm these tests DISCRIMINATE -- they must FAIL against the pre-fix script.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/case"
  mkdir -p "$TMP/bin" "$TMP/deploy"

  SRC="$TMP/src"
  mkdir -p "$SRC/scripts/lib" "$SRC/skills-all"
  git -C "$SRC" init -q
  git -C "$SRC" config user.email t@t.t
  git -C "$SRC" config user.name t
  git -C "$SRC" config commit.gpgsign false

  cp "${ROLLBACK_SH:-$REPO_ROOT/scripts/rollback.sh}" "$SRC/scripts/rollback.sh"
  cp "$REPO_ROOT/scripts/deploy.sh" "$SRC/scripts/deploy.sh"
  # the shared preservation lib, if the implementation under test has one
  for lib in sync-profile-config.sh announce-legit-write.sh; do
    [ -f "$REPO_ROOT/scripts/lib/$lib" ] && cp "$REPO_ROOT/scripts/lib/$lib" "$SRC/scripts/lib/$lib"
  done
  chmod +x "$SRC/scripts/rollback.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SRC/scripts/smoke-test.sh"
  chmod +x "$SRC/scripts/smoke-test.sh"

  # The REPO copy of the profile config: no .mcp block at all, which is the
  # real shape (tokens are never committed).
  printf '%s\n' '{"profile":"main","agents":{"list":[{"id":"cto"}]}}' > "$SRC/openclaw-main.json"
  printf '%s\n' '{"profile":"edge"}' > "$SRC/openclaw-edge.json"
  printf 'GOOD\n' > "$SRC/skills-all/marker.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -qm good
  GOOD_SHA="$(git -C "$SRC" rev-parse HEAD)"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/systemctl"
  chmod +x "$TMP/bin/systemctl"
  export PATH="$TMP/bin:$PATH"

  DEPLOY="$TMP/deploy"
  STATE="$TMP/state"
  mkdir -p "$STATE/.openclaw-main" "$STATE/.openclaw-edge"
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
}

# write a live profile config carrying runtime MCP registrations
live_main() { printf '%s\n' "$1" > "$STATE/.openclaw-main/openclaw.json"; }

run_rollback() {
  run env HYDRA_LOCAL=true DEPLOY_PATH="$DEPLOY" PROFILE_STATE_ROOT="$STATE" \
    SLACK_WEBHOOK="" bash "$SRC/scripts/rollback.sh"
}

live_json() { jq -r "$1" "$STATE/.openclaw-main/openclaw.json"; }

@test "THE REGRESSION: a live MCP server survives a rollback" {
  live_main '{"profile":"stale","mcp":{"servers":{"sentry":{"transport":"streamable-http","url":"https://mcp.sentry.dev/mcp","headers":{"Authorization":"Sentry-Bearer tok"}}}}}'

  run_rollback

  [ "$(live_json '.mcp.servers.sentry.url')" = "https://mcp.sentry.dev/mcp" ]
  # the token is the whole reason this must be preserved -- it is not in git
  [ "$(live_json '.mcp.servers.sentry.headers.Authorization')" = "Sentry-Bearer tok" ]
}

@test "every live MCP server is preserved, not just the first" {
  live_main '{"mcp":{"servers":{"sentry":{"url":"a"},"nocodb":{"url":"b"},"notion":{"url":"c"}}}}'
  run_rollback
  [ "$(live_json '.mcp.servers | length')" -eq 3 ]
  [ "$(live_json '.mcp.servers.nocodb.url')" = "b" ]
}

@test "the repo copy still wins for every field that is not .mcp.servers" {
  live_main '{"profile":"stale","agents":{"list":[{"id":"GHOST"}]},"mcp":{"servers":{"sentry":{"url":"a"}}}}'
  run_rollback
  # rollback's whole job: revert committed config to last-known-good
  [ "$(live_json '.profile')" = "main" ]
  [ "$(live_json '.agents.list[0].id')" = "cto" ]
}

@test "a live config with NO mcp block still rolls back cleanly" {
  live_main '{"profile":"stale"}'
  run_rollback
  [ "$status" -eq 0 ]
  [ "$(live_json '.profile')" = "main" ]
}

@test "an ABSENT live config is created from the repo copy" {
  rm -f "$STATE/.openclaw-main/openclaw.json"
  run_rollback
  [ "$status" -eq 0 ]
  [ "$(live_json '.profile')" = "main" ]
}

@test "an unparseable live config is quarantined, never silently discarded" {
  printf 'this is not json\n' > "$STATE/.openclaw-main/openclaw.json"
  run_rollback
  # the rollback must still land...
  [ "$(live_json '.profile')" = "main" ]
  # ...but the unreadable original must be recoverable by hand: it may have
  # held the only copy of a token.
  ls "$STATE/.openclaw-main/"openclaw.json.corrupted.* >/dev/null 2>&1
}

@test "a non-dict .mcp.servers warns instead of crashing the rollback" {
  live_main '{"mcp":{"servers":["not","a","dict"]}}'
  run_rollback
  [ "$status" -eq 0 ]
  [ "$(live_json '.profile')" = "main" ]
}

@test "the resulting config is valid JSON, not a torn write" {
  live_main '{"mcp":{"servers":{"sentry":{"url":"a"}}}}'
  run_rollback
  run jq -e . "$STATE/.openclaw-main/openclaw.json"
  [ "$status" -eq 0 ]
}
