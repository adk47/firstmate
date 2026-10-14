#!/usr/bin/env bats
# deploy.sh --report-only: run Step 0 (drift) + Step 4a (pre-flight) and exit
# BEFORE anything that mutates (MUS-5083).
#
# These EXECUTE deploy.sh (not static greps) against a stubbed "server": a
# `hostname` stub makes HYDRA_LOCAL=true and DEPLOY_PATH is a scratch dir, so the
# real Step 0 / Step 4a code runs with its real RSYNC_EXCLUDES, drift-check.sh
# and classify-deletions.sh. `ssh`, `npm`, `systemctl`, `kubectl`, `curl` stubs log any
# call to $STUB_LOG; the mutation assertions fail on any of them.

DEPLOY="${BATS_TEST_DIRNAME}/../deploy.sh"
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

setup() {
  WORK="$(mktemp -d)"
  export STUB_LOG="$WORK/stub.log"; : > "$STUB_LOG"
  mkdir -p "$WORK/bin" "$WORK/server" "$WORK/tmp"
  printf '#!/bin/sh\necho node-8\n' > "$WORK/bin/hostname"
  for c in ssh npm systemctl kubectl curl; do
    printf '#!/bin/sh\necho "%s $*" >> "$STUB_LOG"\nexit 1\n' "$c" > "$WORK/bin/$c"
  done
  chmod +x "$WORK/bin/"*
  # The "server" is a pristine export of this checkout's HEAD, baselined at HEAD.
  git -C "$REPO_ROOT" archive HEAD | tar -x -C "$WORK/server"
  git -C "$REPO_ROOT" rev-parse HEAD > "$WORK/server/.deployed-sha"
  cp "$WORK/server/.deployed-sha" "$WORK/baseline.sha"
  export DEPLOY_PATH="$WORK/server" TMPDIR="$WORK/tmp"
}

teardown() { rm -rf "$WORK"; }

run_report() {
  run env PATH="$WORK/bin:$PATH" "$@" bash "$DEPLOY" --report-only
}

# Server-only drift the classifier must NOT auto-exclude: a workspace file that
# was tracked, then deleted from git, but still sits on the server. (A
# never-tracked file is runtime state and is auto-excluded since MUS-5060.)
# Sets $SRC; DEPLOY_PATH is the server baselined at the commit that still had it.
make_ever_tracked_drift() {
  SRC="$WORK/src"; mkdir -p "$SRC"
  git -C "$REPO_ROOT" archive HEAD | tar -x -C "$SRC"
  git -C "$SRC" init -q
  # git spawns a detached `maintenance run --auto` after commits; it races teardown rm -rf
  git -C "$SRC" config gc.auto 0; git -C "$SRC" config maintenance.auto false
  git -C "$SRC" config user.email t@t; git -C "$SRC" config user.name t
  mkdir -p "$SRC/workspaces/ceo"; echo "note" > "$SRC/workspaces/ceo/server-only-note.md"
  git -C "$SRC" add -A; git -C "$SRC" commit -qm base
  rm -rf "$DEPLOY_PATH"; mkdir -p "$DEPLOY_PATH"
  git -C "$SRC" archive HEAD | tar -x -C "$DEPLOY_PATH"
  git -C "$SRC" rm -q workspaces/ceo/server-only-note.md; git -C "$SRC" commit -qm "untrack note"
  git -C "$SRC" rev-parse HEAD > "$DEPLOY_PATH/.deployed-sha"
  cp "$DEPLOY_PATH/.deployed-sha" "$WORK/baseline.sha"
}

run_report_src() {
  run env PATH="$WORK/bin:$PATH" "$@" bash "$SRC/scripts/deploy.sh" --report-only
}

assert_nothing_mutated() {
  [ ! -e "$DEPLOY_PATH/.deploy-mutating" ] || { echo "mutation marker was created"; return 1; }
  cmp -s "$DEPLOY_PATH/.deployed-sha" "$WORK/baseline.sha" || { echo ".deployed-sha changed"; return 1; }
  [ ! -s "$STUB_LOG" ] || { echo "mutating tool called:"; cat "$STUB_LOG"; return 1; }
}

@test "clean tree (HYDRA_FULL_SYNC=1 mirror mode): Step 0 + Step 4a clean, exit 0, nothing mutated" {
  run_report HYDRA_FULL_SYNC=1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Step 0/8"* ]]
  [[ "$output" == *"Pre-flight clean."* ]]
  [[ "$output" != *"Step 4a.5"* ]]
  [[ "$output" != *"Claiming the mutation marker"* ]]
  [[ "$output" != *"Step 4b"* ]]
  assert_nothing_mutated
}

@test "HYDRA_REPORT_ONLY=1 is the env twin of --report-only" {
  run env PATH="$WORK/bin:$PATH" HYDRA_REPORT_ONLY=1 HYDRA_FULL_SYNC=1 bash "$DEPLOY"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Pre-flight clean."* ]]
  assert_nothing_mutated
}

@test "blocking rail (HYDRA_FULL_SYNC=1 mirror mode): ever-tracked server-only workspace file prints the briefing, exits non-zero, nothing mutated" {
  make_ever_tracked_drift
  run_report_src HYDRA_FULL_SYNC=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"server-only-note.md"* ]]
  [[ "$output" == *"refusing to delete server state"* ]]
  assert_nothing_mutated
}

@test "unknown flag is still rejected and the usage names --report-only" {
  run env PATH="$WORK/bin:$PATH" bash "$DEPLOY" --no-such-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"--report-only"* ]]
}

@test "the report-only exit sits before the muso pin and the marker claim" {
  exit_line=$(grep -nE '^\s*log "--report-only: Step 0 and Step 4a are clean' "$DEPLOY" | head -1 | cut -d: -f1)
  pin=$(grep -nE '^\s*if ! install_muso; then' "$DEPLOY" | head -1 | cut -d: -f1)
  claim=$(grep -nE '^\s*claim_mutation_marker ' "$DEPLOY" | head -1 | cut -d: -f1)
  [ "$exit_line" -lt "$pin" ] && [ "$exit_line" -lt "$claim" ]
}

@test "blocking rail with SLACK_WEBHOOK set posts nothing (a report is not a failed deploy)" {
  make_ever_tracked_drift
  run_report_src HYDRA_FULL_SYNC=1 SLACK_WEBHOOK=http://example.invalid/hook
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to delete server state"* ]]
  assert_nothing_mutated
}

@test "HYDRA_FORCE=1 is refused: a bypassed rail must not be reported clean" {
  make_ever_tracked_drift
  run_report_src HYDRA_FORCE=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--report-only"* ]]
  [[ "$output" != *"are clean"* ]]
  assert_nothing_mutated
}

@test "HYDRA_SKIP_DRIFT_CHECK=1 is refused: a bypassed rail must not be reported clean" {
  make_ever_tracked_drift
  run_report_src HYDRA_SKIP_DRIFT_CHECK=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--report-only"* ]]
  [[ "$output" != *"are clean"* ]]
  assert_nothing_mutated
}

@test "a real .git checkout: report-only does not run setup-hooks.sh (core.hooksPath untouched)" {
  SRC="$WORK/src"; mkdir -p "$SRC"
  git -C "$REPO_ROOT" archive HEAD | tar -x -C "$SRC"
  git -C "$SRC" init -q
  # git spawns a detached `maintenance run --auto` after commits; it races teardown rm -rf
  git -C "$SRC" config gc.auto 0; git -C "$SRC" config maintenance.auto false
  git -C "$SRC" config user.email t@t; git -C "$SRC" config user.name t
  git -C "$SRC" add -A; git -C "$SRC" commit -qm base
  rm -rf "$DEPLOY_PATH"; mkdir -p "$DEPLOY_PATH"
  git -C "$SRC" archive HEAD | tar -x -C "$DEPLOY_PATH"
  git -C "$SRC" rev-parse HEAD > "$DEPLOY_PATH/.deployed-sha"
  cp "$DEPLOY_PATH/.deployed-sha" "$WORK/baseline.sha"
  run env PATH="$WORK/bin:$PATH" bash "$SRC/scripts/deploy.sh" --report-only
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$(git -C "$SRC" config --get core.hooksPath || true)" ] || { echo "core.hooksPath was written"; return 1; }
  assert_nothing_mutated
}
