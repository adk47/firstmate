#!/usr/bin/env bats
#
# scripts/rollback.sh — rollback target resolution.
#
# REGRESSION THIS SUITE EXISTS FOR (2026-08-06, deploy run 31080741548):
# rollback.sh used to rsync "$HYDRA_ROOT/" — the checkout at the FAILED commit —
# into /opt/hydra/, reverting only openclaw-{main,edge}.json to HEAD~1. So a
# failed deploy FORWARD-deployed the failing commit's skills-all/, scripts/ and
# workspace seeds. It must instead restore the server's last-known-good SHA
# (/opt/hydra/.deployed-sha, written by deploy.sh only after the smoke test
# passes and excluded from rsync so it survives a failure) — and when that
# cannot be established it must sync NOTHING rather than push the failure.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/case"
  mkdir -p "$TMP/bin" "$TMP/deploy"

  # --- a two-commit source repo: GOOD then BAD -----------------------------
  SRC="$TMP/src"
  mkdir -p "$SRC/scripts/lib" "$SRC/skills-all"
  git -C "$SRC" init -q 2>/dev/null || { mkdir -p "$SRC"; git -C "$SRC" init -q; }
  git -C "$SRC" config user.email t@t.t
  git -C "$SRC" config user.name t
  git -C "$SRC" config commit.gpgsign false

  # ROLLBACK_SH lets a reviewer point the suite at a different implementation
  # to confirm these tests DISCRIMINATE (they must fail against the pre-fix
  # script, not merely pass against the new one).
  cp "${ROLLBACK_SH:-$REPO_ROOT/scripts/rollback.sh}" "$SRC/scripts/rollback.sh"
  # The real deploy.sh: rollback.sh DERIVES its rsync excludes from that file's
  # RSYNC_EXCLUDES literals, so the suite must exercise the real parse (and will
  # notice if a deploy.sh refactor breaks it).
  cp "$REPO_ROOT/scripts/deploy.sh" "$SRC/scripts/deploy.sh"
  # rollback.sh sources these; without them the script dies at `source` under
  # `set -e` and every assertion below fails for the wrong reason.
  cp "$REPO_ROOT/scripts/lib/sync-profile-config.sh" "$SRC/scripts/lib/sync-profile-config.sh"
  # rollback.sh sources the mutation-marker lib (PR #948); the synthetic repo needs it too.
  cp "$REPO_ROOT/scripts/lib/deploy-mutation-marker.sh" "$SRC/scripts/lib/deploy-mutation-marker.sh"
  [ -f "$REPO_ROOT/scripts/lib/announce-legit-write.sh" ] \
    && cp "$REPO_ROOT/scripts/lib/announce-legit-write.sh" "$SRC/scripts/lib/announce-legit-write.sh"
  chmod +x "$SRC/scripts/rollback.sh"
  # smoke-test.sh is invoked by Step 3; make it a pass-through.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SRC/scripts/smoke-test.sh"
  chmod +x "$SRC/scripts/smoke-test.sh"

  printf 'GOOD\n' > "$SRC/skills-all/marker.md"
  # Step 1b of the rollback copies the synced tree's profile configs into the
  # live profile dirs; carry one so that path is exercised (against the injected
  # root below, never /root/.openclaw-*).
  printf '{"profile":"main"}\n' > "$SRC/openclaw-main.json"
  git -C "$SRC" add -A
  git -C "$SRC" commit -qm good
  GOOD_SHA="$(git -C "$SRC" rev-parse HEAD)"

  printf 'BAD\n' > "$SRC/skills-all/marker.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -qm bad
  BAD_SHA="$(git -C "$SRC" rev-parse HEAD)"

  # --- stubs ---------------------------------------------------------------
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/systemctl"
  chmod +x "$TMP/bin/systemctl"
  export PATH="$TMP/bin:$PATH"

  DEPLOY="$TMP/deploy"
  printf 'STALE\n' > "$DEPLOY/skills-all-marker-placeholder"

  # The profile-sync destination root. HYDRA_LOCAL=true is the seam that lets
  # this suite exercise the local sync path, and the self-hosted runner IS
  # node-8 running as root — without this redirect every green test would copy
  # over the LIVE /root/.openclaw-{main,edge}/openclaw.json. Every write this
  # suite makes must stay under $BATS_TEST_TMPDIR.
  STATE="$TMP/state"
  mkdir -p "$STATE"

  export HYDRA_LOCAL=true
  export DEPLOY_PATH="$DEPLOY"
  export PROFILE_STATE_ROOT="$STATE"
  export SLACK_WEBHOOK=""
}

run_rollback() {
  run env HYDRA_LOCAL=true DEPLOY_PATH="$DEPLOY" PROFILE_STATE_ROOT="$STATE" \
    SLACK_WEBHOOK="" \
    bash "$SRC/scripts/rollback.sh"
}

@test "restores the last-known-good tree, NOT the failed commit" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"

  run_rollback

  [ -f "$DEPLOY/skills-all/marker.md" ]
  # The regression: this used to be BAD (the failed commit's content).
  [ "$(cat "$DEPLOY/skills-all/marker.md")" = "GOOD" ]
}

@test "a mutation marker present before a successful rollback is absent afterwards" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  : > "$DEPLOY/.deploy-mutating"

  run_rollback

  [ ! -f "$DEPLOY/.deploy-mutating" ]
}

@test "a marker the rollback cannot clear FAILS the rollback before the success notice (QA Important round 4, PR #948)" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  # rm -f cannot remove a non-empty directory: stands in for a transient
  # cleanup failure on the server.
  mkdir -p "$DEPLOY/.deploy-mutating/keep"; : > "$DEPLOY/.deploy-mutating/keep/x"

  run_rollback

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not clear"* ]]
  if [[ "$output" == *"Rollback complete."* ]]; then false; fi
}

@test "does not leave the failed commit's content on the server" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  run_rollback
  ! grep -qr 'BAD' "$DEPLOY/skills-all/" 2>/dev/null
}

@test "fail-safe: absent .deployed-sha syncs NOTHING and exits non-zero" {
  rm -f "$DEPLOY/.deployed-sha"

  run_rollback

  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to sync"* ]]
  # Nothing from either commit may have landed.
  [ ! -f "$DEPLOY/skills-all/marker.md" ]
}

@test "fail-safe: malformed .deployed-sha syncs NOTHING and exits non-zero" {
  printf 'not-a-sha\n' > "$DEPLOY/.deployed-sha"

  run_rollback

  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to sync"* ]]
  [ ! -f "$DEPLOY/skills-all/marker.md" ]
}

@test "fail-safe: unknown commit SHA syncs NOTHING and exits non-zero" {
  printf '%s\n' "0123456789abcdef0123456789abcdef01234567" > "$DEPLOY/.deployed-sha"

  run_rollback

  [ "$status" -ne 0 ]
  [ ! -f "$DEPLOY/skills-all/marker.md" ]
}

@test "HEAD~1 is not used as the target when it differs from .deployed-sha" {
  # Third commit: now HEAD~1 is BAD, while last-known-good is still GOOD.
  printf 'WORSE\n' > "$SRC/skills-all/marker.md"
  git -C "$SRC" add -A
  git -C "$SRC" commit -qm worse
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"

  run_rollback

  # HEAD~1 would give BAD; the deployed baseline gives GOOD.
  [ "$(cat "$DEPLOY/skills-all/marker.md")" = "GOOD" ]
}

@test "removes a file the FAILED deploy added (delete semantics)" {
  # A deploy that fails at/after its smoke test has already rsynced. Without
  # --delete the rollback leaves that commit's new files behind and the server
  # ends up mixed-version — the exact state this script exists to prevent.
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  mkdir -p "$DEPLOY/scripts"
  printf 'from the bad deploy\n' > "$DEPLOY/scripts/bad-new-file.sh"

  run_rollback

  [ ! -f "$DEPLOY/scripts/bad-new-file.sh" ]
}

# Regression for 2026-08-27. deploy.sh Step 4a refused a sync because it would
# delete four workspaces/operations/*.sql files the ops agent had written; the
# failure path then ran this script and rsync --delete removed them. The .csv
# siblings survived only because workspaces/*/*.csv is in RSYNC_EXCLUDES -- an
# exclude list spares only what someone predicted, and the agents keep inventing
# file types nobody listed.
#
# Both halves matter, so both are asserted here: agent-authored state under
# workspaces/ survives, AND the failed deploy's own additions are still removed.
# An earlier version of this fix disarmed --delete entirely and passed the first
# assertion while silently breaking the second.
@test "SAFETY: agent-authored files an exclude never predicted survive --delete" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  mkdir -p "$DEPLOY/workspaces/operations" "$DEPLOY/scripts"

  # the shape that was destroyed: unlisted extension next to a listed one
  printf 'SELECT 1\n'  > "$DEPLOY/workspaces/operations/roc_legion_track_stats.sql"
  printf 'a,b\n'       > "$DEPLOY/workspaces/operations/roc_legion_track_stats.csv"
  # and a file the failed deploy added, which must STILL be removed
  printf 'from the bad deploy\n' > "$DEPLOY/scripts/bad-new-file.sh"

  run_rollback

  [ -f "$DEPLOY/workspaces/operations/roc_legion_track_stats.sql" ]
  [ "$(cat "$DEPLOY/workspaces/operations/roc_legion_track_stats.sql")" = "SELECT 1" ]
  [ -f "$DEPLOY/workspaces/operations/roc_legion_track_stats.csv" ]
  [ ! -f "$DEPLOY/scripts/bad-new-file.sh" ]
}

@test "SAFETY: a file written just before the sync is still protected (no TOCTOU)" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  mkdir -p "$DEPLOY/skills-all" "$DEPLOY/scripts"
  printf 'late\n' > "$DEPLOY/skills-all/late.sql"
  printf 'from the bad deploy\n' > "$DEPLOY/scripts/bad-new-file.sh"

  run_rollback

  [ -f "$DEPLOY/skills-all/late.sql" ]
  [ ! -f "$DEPLOY/scripts/bad-new-file.sh" ]
}

# protect spares from --delete but must NOT skip the transfer: last-known-good
# content still has to overwrite whatever the failed deploy left.
@test "SAFETY: protected trees still get last-known-good CONTENT restored" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  mkdir -p "$DEPLOY/skills-all"
  printf 'BAD\n' > "$DEPLOY/skills-all/marker.md"

  run_rollback

  [ "$(cat "$DEPLOY/skills-all/marker.md")" = "GOOD" ]
}

@test "SAFETY: --delete must NOT wipe protected server state" {
  # The counterpart to the test above. Deleting with a truncated exclude list
  # during an incident would destroy live agent state that has no backup, which
  # is strictly worse than leaving a stray file. These paths are in deploy.sh's
  # RSYNC_EXCLUDES and must survive.
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  mkdir -p "$DEPLOY/workspaces/ops/memory" "$DEPLOY/workspaces/ops/reports" "$DEPLOY/secrets"
  printf 'long-term\n'  > "$DEPLOY/workspaces/ops/MEMORY.md"
  printf 'snapshot\n'   > "$DEPLOY/workspaces/ops/memory/x.json"
  printf 'pii\n'        > "$DEPLOY/workspaces/ops/reports/r.csv"
  printf 'token\n'      > "$DEPLOY/secrets/creds"
  printf 'scratch\n'    > "$DEPLOY/workspaces/ops/prep-output-2026-08-05.json"

  run_rollback

  [ -f "$DEPLOY/workspaces/ops/MEMORY.md" ]
  [ -f "$DEPLOY/workspaces/ops/memory/x.json" ]
  [ -f "$DEPLOY/workspaces/ops/reports/r.csv" ]
  [ -f "$DEPLOY/secrets/creds" ]
  [ -f "$DEPLOY/workspaces/ops/prep-output-2026-08-05.json" ]
  # and .deployed-sha itself must not be deleted
  [ -f "$DEPLOY/.deployed-sha" ]
}

@test "fail-closed: unparseable deploy.sh disables --delete instead of guessing" {
  # Unparseable in BOTH trees: the policy is the union of the failed checkout's
  # deploy.sh and the last-known-good tree's, so clobbering only one leaves the
  # other in force (asserted separately below).
  printf 'GOOD\n' > "$SRC/skills-all/marker.md"
  printf '# no exclude list here\n' > "$SRC/scripts/deploy.sh"
  git -C "$SRC" add -A
  git -C "$SRC" commit -qm "good, no exclude list"
  git -C "$SRC" rev-parse HEAD > "$DEPLOY/.deployed-sha"
  mkdir -p "$DEPLOY/scripts"
  printf 'stray\n' > "$DEPLOY/scripts/bad-new-file.sh"

  run_rollback

  [[ "$output" == *"WITHOUT --delete"* ]]
  # Degraded, not destructive: the stray file survives...
  [ -f "$DEPLOY/scripts/bad-new-file.sh" ]
  # ...and the good tree still lands.
  [ "$(cat "$DEPLOY/skills-all/marker.md")" = "GOOD" ]
}

@test "SAFETY: a protected exclude dropped by the FAILED checkout cannot arm a wipe" {
  # The rollback executes FROM the checkout of the commit that just failed. If
  # that tree's deploy.sh were the only policy source, a commit dropping ONE
  # --exclude line (78 remain — every count threshold still satisfied) would
  # turn the rollback into a permanent delete of unbacked live state.
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  grep -vF -- "--exclude='workspaces/*/memory/'" \
    "$REPO_ROOT/scripts/deploy.sh" > "$SRC/scripts/deploy.sh"
  mkdir -p "$DEPLOY/workspaces/ops/memory" "$DEPLOY/scripts"
  printf 'snapshot\n' > "$DEPLOY/workspaces/ops/memory/x.json"
  printf 'stray\n'    > "$DEPLOY/scripts/bad-new-file.sh"

  run_rollback

  # The last-known-good tree's policy still covers memory/ ...
  [ -f "$DEPLOY/workspaces/ops/memory/x.json" ]
  # ... and this is NOT the degraded path: --delete stays armed.
  [ ! -f "$DEPLOY/scripts/bad-new-file.sh" ]
  [[ "$output" != *"WITHOUT --delete"* ]]
}

@test "SAFETY: a mandatory exclude missing from BOTH trees disables --delete" {
  # The count can't see this: 78 excludes is well above any floor, so only an
  # explicit per-pattern requirement fails closed here.
  printf 'GOOD\n' > "$SRC/skills-all/marker.md"
  grep -vF -- "--exclude='workspaces/*/memory/'" \
    "$REPO_ROOT/scripts/deploy.sh" > "$SRC/scripts/deploy.sh"
  git -C "$SRC" add -A
  git -C "$SRC" commit -qm "good, memory/ exclude dropped"
  git -C "$SRC" rev-parse HEAD > "$DEPLOY/.deployed-sha"
  mkdir -p "$DEPLOY/workspaces/ops/memory" "$DEPLOY/scripts"
  printf 'snapshot\n' > "$DEPLOY/workspaces/ops/memory/x.json"
  printf 'stray\n'    > "$DEPLOY/scripts/bad-new-file.sh"

  run_rollback

  [[ "$output" == *"missing mandatory protected pattern"* ]]
  [[ "$output" == *"WITHOUT --delete"* ]]
  # Degraded, not destructive.
  [ -f "$DEPLOY/workspaces/ops/memory/x.json" ]
  [ -f "$DEPLOY/scripts/bad-new-file.sh" ]
  [ "$(cat "$DEPLOY/skills-all/marker.md")" = "GOOD" ]
}

@test "profile sync writes under the injected root, never the live /root state" {
  # Discrimination: against the pre-fix script (hardcoded /opt/hydra ->
  # /root/.openclaw-*) nothing lands here — and on the self-hosted runner, which
  # is node-8 as root, the live profile config is overwritten instead.
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"

  run_rollback

  [ "$status" -eq 0 ]
  [ -f "$STATE/.openclaw-main/openclaw.json" ]
  # NOT byte-equality with the repo copy. Since 2026-08-26 the profile sync
  # PRESERVES the live `.mcp.servers` block (scripts/lib/sync-profile-config.sh)
  # and re-serialises, so the result is correctly not byte-identical. Asserting
  # equality here would re-assert the bug that destroyed the Sentry MCP
  # registration. Assert the repo copy WON instead.
  [ "$(jq -r .profile "$STATE/.openclaw-main/openclaw.json")" = "main" ]
  [[ "$STATE" == "$BATS_TEST_TMPDIR"* ]]
}

@test "derives the full exclude list from deploy.sh, not a stale copy" {
  # Guards the drift this replaced: the old hand-maintained ROLLBACK_EXCLUDES
  # had 19 entries while deploy.sh had grown to ~79.
  n=$(sed -n '/^RSYNC_EXCLUDES=(/,/^)/p' "$REPO_ROOT/scripts/deploy.sh" \
        | grep -v '^[[:space:]]*#' \
        | grep -c -- "--exclude='")
  [ "$n" -ge 20 ]
}

@test "leaves no leftover git worktree in the source checkout" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  run_rollback
  run git -C "$SRC" worktree list
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}
