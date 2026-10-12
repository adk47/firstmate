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
  # rollback.sh takes the main-prune lock (MUS-3742); the /run/lock default may not exist on a test host.
  cp "$REPO_ROOT/scripts/lib/main-prune-lock.sh" "$SRC/scripts/lib/main-prune-lock.sh"
  export MAIN_PRUNE_LOCK_FILE="$TMP/main-prune.lock"
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

# One process holds the lock (exec): kill $! releases it and leaves no orphan holding bats' fds.
_hold_lock() { bash -c 'exec 8>"$1"; flock -n 8 && exec sleep "$2"' _ "$1" "$2" >/dev/null 2>&1 3>&- & }

run_rollback() {
  run env HYDRA_LOCAL=true DEPLOY_PATH="$DEPLOY" PROFILE_STATE_ROOT="$STATE" \
    OPENCLAW_PROFILE_ROOT="$TMP/oc" SLACK_WEBHOOK="" \
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

  [ "$status" -eq 0 ]
  [ ! -f "$DEPLOY/.deploy-mutating" ]
  [[ "$output" == *"Rollback complete."* ]]
}

@test "a smoke-test failure after rollback still exits non-zero AND the marker is already cleared (issue #984)" {
  # Regression for 2026-09-21: the marker clear used to sit AFTER the smoke
  # test, so a smoke-test failure (e.g. the post-restart event-loop freeze,
  # issue #984) left the marker behind and blocked every later deploy for
  # 16h even though the tree was already restored and the gateways already
  # restarted. The clear must happen before the smoke test runs, so it has
  # already happened by the time the smoke test fails.
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  : > "$DEPLOY/.deploy-mutating"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SRC/scripts/smoke-test.sh"
  chmod +x "$SRC/scripts/smoke-test.sh"

  run_rollback

  [ "$status" -ne 0 ]
  [[ "$output" == *"Smoke test FAILED"* ]]
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

@test "restores the exec bit on a directly-exec'd script committed 100644 (2026-09-22 203/EXEC incident, QA #1001)" {
  # scripts/hydra-daily-audit.py is a real ExecStart-by-path target (see
  # scripts/tests/exec-bits-guard.bats); it is what actually landed 100644
  # and 203/EXEC'd hydra-daily-audit.service in the 2026-09-22 08:00Z
  # incident. The guard added in this branch proves the git INDEX carries
  # 100755 for such targets, but says nothing about the rollback path: if a
  # last-known-good tree still has this file at 100644 (e.g. it predates the
  # +x fix, or a future commit drops the mode bit again), rsync does not
  # preserve +x, and only the post-rsync `chmod +x .../scripts/*.py` block in
  # rollback.sh (search "Script permissions fixed") stands between that tree
  # and another 203/EXEC. This drives the REAL rollback.sh entrypoint end to
  # end (HYDRA_LOCAL=true, same seam every other test in this file uses) and
  # asserts the deployed file, not the git index, is executable.
  printf '#!/usr/bin/env python3\nprint("audit")\n' > "$SRC/scripts/hydra-daily-audit.py"
  chmod 644 "$SRC/scripts/hydra-daily-audit.py"
  git -C "$SRC" add -A
  git -C "$SRC" commit -qm "add hydra-daily-audit.py at 644 (pre-fix mode)"
  LKG_WITH_644_SCRIPT_SHA="$(git -C "$SRC" rev-parse HEAD)"
  printf '%s\n' "$LKG_WITH_644_SCRIPT_SHA" > "$DEPLOY/.deployed-sha"

  run_rollback

  [ "$status" -eq 0 ]
  [ -f "$DEPLOY/scripts/hydra-daily-audit.py" ]
  [ -x "$DEPLOY/scripts/hydra-daily-audit.py" ]
}

@test "fails the rollback when restoring +x fails, instead of logging success (QA #1001)" {
  # The chmod used to end in `|| true` and the next line always logged
  # "Script permissions fixed", so a failed repair (read-only mount, foreign
  # ownership) shipped non-executable scripts and a green rollback.
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/chmod"
  command chmod +x "$TMP/bin/chmod"

  run_rollback

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not restore +x"* ]]
  [[ "$output" != *"Script permissions fixed"* ]]
}

@test "leaves no leftover git worktree in the source checkout" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  run_rollback
  run git -C "$SRC" worktree list
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

# ── runtime restore (8 Oct, deploy run 37791745129) ───────────────────────────
# deploy.sh Step 4c.5 swaps the GLOBAL openclaw binary before Step 4d.5 can fail.
# rollback.sh restored only the tree, so node-8 was left with runtime 2026.8.35
# under 2026.8.2 plugins. deploy.sh records the pre-swap version in
# $DEPLOY_PATH/.pre-deploy-openclaw-version (line 1 = runtime, line 2 = each state
# DB's user_version at swap time; removed once Step 6 is done); rollback.sh
# reinstalls the runtime BEFORE restarting the gateways, but only while every
# state DB's user_version still equals line 2 (CTO ruling, MUS-5232).

stub_npm_and_openclaw() {
  export NPM_LOG="$TMP/npm.log"; : > "$NPM_LOG"
  printf '#!/usr/bin/env bash\necho "npm $*" >> "$NPM_LOG"\n[ -z "${NPM_RC:-}" ] || exit "$NPM_RC"\nif [ "$1 $2" = "install -g" ]; then echo "${3#openclaw@}" > "$TMP/runtime-version"; fi\nexit 0\n' > "$TMP/bin/npm"
  printf '#!/usr/bin/env bash\nif [ "$1" = "--version" ]; then echo "OpenClaw $(cat "$TMP/runtime-version") (abc1234)"; fi\nexit 0\n' > "$TMP/bin/openclaw"
  chmod +x "$TMP/bin/npm" "$TMP/bin/openclaw"
  export TMP
  echo "2026.8.35" > "$TMP/runtime-version"
}

# write_record <runtime> — creates both profiles' state DBs at user_version 15
# and records <runtime> with the matching "main=15 edge=15" line.
write_record() {
  for p in main edge; do
    mkdir -p "$TMP/oc/.openclaw-$p/state"
    sqlite3 "$TMP/oc/.openclaw-$p/state/openclaw.sqlite" "pragma user_version=15;"
  done
  printf '%s\nmain=15 edge=15\n' "$1" > "$DEPLOY/.pre-deploy-openclaw-version"
}

@test "a recorded pre-deploy runtime is reinstalled before the gateways restart, then the record is cleared" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_npm_and_openclaw
  write_record 2026.8.2

  run_rollback

  [ "$status" -eq 0 ]
  grep -qxF "npm install -g openclaw@2026.8.2" "$NPM_LOG"
  [ "$(cat "$TMP/runtime-version")" = "2026.8.2" ]
  [ ! -f "$DEPLOY/.pre-deploy-openclaw-version" ]
}

@test "no recorded runtime (the swap never happened or gateways already ran it): npm is never touched" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_npm_and_openclaw

  run_rollback

  [ "$status" -eq 0 ]
  [ ! -s "$NPM_LOG" ]
  [ "$(cat "$TMP/runtime-version")" = "2026.8.35" ]
}

@test "a runtime restore that fails FAILS the rollback and keeps the record (no silent mixed state)" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_npm_and_openclaw
  write_record 2026.8.2

  NPM_RC=1 run_rollback

  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime"* ]]
  [ -f "$DEPLOY/.pre-deploy-openclaw-version" ]
}

@test "state DB user_version moved since the swap: the old binary is NOT installed, record kept, rollback still completes" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_npm_and_openclaw; stub_systemctl_log
  write_record 2026.8.2
  sqlite3 "$TMP/oc/.openclaw-main/state/openclaw.sqlite" "pragma user_version=16;"

  run_rollback

  [ "$status" -eq 0 ]
  [ ! -s "$NPM_LOG" ]
  [ "$(cat "$TMP/runtime-version")" = "2026.8.35" ]
  [ -f "$DEPLOY/.pre-deploy-openclaw-version" ]
  [[ "$output" == *"main=15 edge=15"* && "$output" == *"main=16 edge=15"* ]]
  grep -qxF "systemctl restart openclaw-gateway-main" "$SYSTEMCTL_LOG"
}

@test "an old one-line record (no user_version to compare) is refused, never guessed" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_npm_and_openclaw
  write_record 2026.8.2
  echo "2026.8.2" > "$DEPLOY/.pre-deploy-openclaw-version"

  run_rollback

  [ "$status" -eq 0 ]
  [ ! -s "$NPM_LOG" ]
  [ -f "$DEPLOY/.pre-deploy-openclaw-version" ]
}

@test "an unreadable state DB is refused, never treated as unchanged" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_npm_and_openclaw
  write_record 2026.8.2
  printf 'not a database' > "$TMP/oc/.openclaw-edge/state/openclaw.sqlite"

  run_rollback

  [ "$status" -eq 0 ]
  [ ! -s "$NPM_LOG" ]
  [ -f "$DEPLOY/.pre-deploy-openclaw-version" ]
}

# ── availability window (MUS-5079): deploy.sh stops a gateway at Step 4d and only
# its own Step 6 starts it again. Every rollback exit before rollback's Step 2
# restart must still leave BOTH gateways started.

stub_systemctl_log() {
  export SYSTEMCTL_LOG="$TMP/systemctl.log"; : > "$SYSTEMCTL_LOG"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$SYSTEMCTL_LOG"\nexit 0\n' > "$TMP/bin/systemctl"
  chmod +x "$TMP/bin/systemctl"
}

assert_both_gateways_started() {
  grep -qxF "systemctl start openclaw-gateway-main" "$SYSTEMCTL_LOG"
  grep -qxF "systemctl start openclaw-gateway-edge" "$SYSTEMCTL_LOG"
}

@test "availability: runtime restore failure (exit before Step 2) still starts both gateways" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_npm_and_openclaw; stub_systemctl_log
  write_record 2026.8.2
  NPM_RC=1 run_rollback
  [ "$status" -ne 0 ]
  assert_both_gateways_started
}

@test "availability: unreadable last-known-good SHA (earliest exit) still starts both gateways" {
  printf 'not-a-sha\n' > "$DEPLOY/.deployed-sha"
  stub_systemctl_log
  run_rollback
  [ "$status" -ne 0 ]
  assert_both_gateways_started
}

@test "availability: a rollback that completes Step 2 does not start them a second time" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_systemctl_log
  run_rollback
  [ "$status" -eq 0 ]
  grep -qxF "systemctl restart openclaw-gateway-main" "$SYSTEMCTL_LOG"
  grep -qxF "systemctl restart openclaw-gateway-edge" "$SYSTEMCTL_LOG"
  if grep -q "systemctl start" "$SYSTEMCTL_LOG"; then echo "NEGATED ASSERTION FAILED: backstop fired after Step 2" >&2; false; fi
}

# Asserts on the recorded argv, not on which branch ran: any `systemctl start|restart` here is a start without the lock.
assert_no_systemctl_start() {
  if grep -qE "^systemctl (start|restart)" "$SYSTEMCTL_LOG"; then
    echo "started a gateway without the main prune lock:" >&2; cat "$SYSTEMCTL_LOG" >&2; false
  fi
}

# MUS-3742: rollback.sh restarts with raw systemctl, so it takes the shared prune lock once, before any mutation.
@test "rollback REFUSES while a main prune holds the lock: nothing is synced or restarted" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_systemctl_log
  _hold_lock "$MAIN_PRUNE_LOCK_FILE" 30; holder=$!
  sleep 1
  run env HYDRA_LOCAL=true DEPLOY_PATH="$DEPLOY" PROFILE_STATE_ROOT="$STATE" SLACK_WEBHOOK="" \
    MAIN_PRUNE_LOCK_WAIT_SECS=1 bash "$SRC/scripts/rollback.sh"
  kill "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"still holds"* ]]
  # server left as-is: the restore never ran
  [ ! -f "$DEPLOY/skills-all/marker.md" ]
  # the availability backstop must NOT start main without the lock: the prune has main stopped for offline cleanup
  assert_no_systemctl_start
}

@test "rollback refuses (loudly, nothing touched) when the lock file cannot be opened" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_systemctl_log
  run env HYDRA_LOCAL=true DEPLOY_PATH="$DEPLOY" PROFILE_STATE_ROOT="$STATE" SLACK_WEBHOOK="" \
    MAIN_PRUNE_LOCK_FILE=/dev/null/nope.lock bash "$SRC/scripts/rollback.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot open"* ]]
  [ ! -f "$DEPLOY/skills-all/marker.md" ]
  assert_no_systemctl_start
}

# ssh mode (laptop rollback): the lock is held ON node-8 by a background ssh; a refusal must not start main either.
# The fake ssh runs the remote command (its last argument) locally, so the real remote flock runs on the test lock file.
stub_ssh_local() {
  printf '#!/usr/bin/env bash\nbash -c "${@: -1}"\n' > "$TMP/bin/ssh"
  chmod +x "$TMP/bin/ssh"
}

@test "ssh-mode rollback REFUSES while a main prune holds the lock on node-8: nothing synced, no gateway started" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_systemctl_log; stub_ssh_local
  _hold_lock "$MAIN_PRUNE_LOCK_FILE" 30; holder=$!
  sleep 1
  run env HYDRA_LOCAL=false DEPLOY_PATH="$DEPLOY" PROFILE_STATE_ROOT="$STATE" SLACK_WEBHOOK="" \
    MAIN_PRUNE_LOCK_WAIT_SECS=1 bash "$SRC/scripts/rollback.sh"
  kill "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not take"* ]]
  [ ! -f "$DEPLOY/skills-all/marker.md" ]
  assert_no_systemctl_start
}

# The ssh holding the node-8 prune lock dies mid-rollback (link drop): the watcher aborts rollback, and the EXIT
# backstop must not then start main unlocked (the prune may now hold the store). Non-lock ssh calls are slowed so
# rollback is still running when the holder dies.
@test "ssh-mode rollback aborts when the node-8 lock holder dies mid-run and starts no gateway" {
  printf '%s\n' "$GOOD_SHA" > "$DEPLOY/.deployed-sha"
  stub_systemctl_log
  cat > "$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="${@: -1}"
case "$cmd" in
  *flock*) bash -c "$cmd" & p=$!; ( sleep 1; kill -9 "$p" 2>/dev/null ) >/dev/null 2>&1 & wait "$p" ;;
  *) sleep 5; bash -c "$cmd" ;;
esac
STUB
  chmod +x "$TMP/bin/ssh"
  run env HYDRA_LOCAL=false DEPLOY_PATH="$DEPLOY" PROFILE_STATE_ROOT="$STATE" SLACK_WEBHOOK="" \
    MAIN_PRUNE_LOCK_WATCH_SECS=0.2 bash "$SRC/scripts/rollback.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"holding the main prune lock"*"died"* ]]
  [[ "$output" == *"main prune lock lost"* ]]
  assert_no_systemctl_start
}
