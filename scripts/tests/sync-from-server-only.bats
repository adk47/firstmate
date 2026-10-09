#!/usr/bin/env bats
# Tests for sync-from-server.sh --only <path> mode: capture a single drifted
# file without clobbering the PR's other skill edits (adversarial P1-4). rsync
# and ssh are PATH-shadowed so nothing touches real node-8 (see
# memory/feedback_bats_must_stub_openclaw.md).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/sync-from-server.sh"
# Real git-tracked paths: --only refuses untracked ones. A skill rename is a one-line fix here.
readonly TRACKED_A=skills-all/babysit/SKILL.md TRACKED_B=skills-all/agent-bridge-request/SKILL.md

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR RSYNC_CALLS="$TEST_TMPDIR/rsync.calls"
  : > "$RSYNC_CALLS"

  mkdir -p "$TEST_TMPDIR/bin"
  # rsync stub: record argv, emit a fake itemize transfer line so the script's
  # n>0 "would be pulled" path is exercised. Never touches the filesystem.
  cat > "$TEST_TMPDIR/bin/rsync" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$RSYNC_CALLS"
echo ">f.st...... skills-all/babysit/SKILL.md"
exit 0
STUB
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh refused ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/rsync" "$TEST_TMPDIR/bin/ssh"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # Point SSH at a sentinel key so the script skips ~/.ssh probing.
  export SSH_KEY=/dev/null NODE8_IP=127.0.0.1 NODE8_USER=root DEPLOY_PATH=/opt/hydra
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "bulk pull (no --only) transfers a tracked-only --files-from list, not the whole dir" {
  run "$SCRIPT" skills
  [ "$status" -eq 0 ]
  # Bulk source is the deploy root + a tracked file list (tracked-only rule,
  # see sync-from-server-tracked-only.bats), not a /./ -R anchor.
  grep -qF -- '--files-from=' "$RSYNC_CALLS"
  ! grep -qF '/./skills-all/' "$RSYNC_CALLS"
}

@test "--only pulls just the named file (dry-run default), with -R anchor" {
  run "$SCRIPT" skills --only $TRACKED_A
  [ "$status" -eq 0 ]
  # -R relative anchor on the single file, not a bulk dir pull.
  grep -qF "/./$TRACKED_A" "$RSYNC_CALLS"
  # Dry-run by default → rsync invoked with -n.
  grep -qE '(^| )-n( |$)|-az[A-Za-z]*n' "$RSYNC_CALLS"
}

@test "--only --apply drops the dry-run flag" {
  run "$SCRIPT" skills --apply --only $TRACKED_A
  [ "$status" -eq 0 ]
  grep -qF "/./$TRACKED_A" "$RSYNC_CALLS"
  # No standalone -n in apply mode.
  ! grep -qE '(^| )-n( |$)' "$RSYNC_CALLS"
}

@test "--only is repeatable (two files → two rsync calls)" {
  run "$SCRIPT" skills --only $TRACKED_A --only $TRACKED_B
  [ "$status" -eq 0 ]
  grep -qF "/./$TRACKED_A" "$RSYNC_CALLS"
  grep -qF "/./$TRACKED_B" "$RSYNC_CALLS"
  [ "$(grep -c . "$RSYNC_CALLS")" -eq 2 ]
}

@test "--only with no path argument fails loudly" {
  run "$SCRIPT" skills --only
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'only'
}

@test "--only with the workspaces target accepts a workspaces/*/skills/ path (MUS-1792 round 2: the command the drift briefings now print)" {
  # QA's NO-GO reproduced the operator failure end-to-end: deploy.sh's and
  # pr-skill-drift-gate.sh's remediation printers must pick the 'workspaces'
  # target for a workspaces/ path, or this exact command exits 1 with "not
  # under the 'skills' target". This proves the FIXED command (workspaces
  # target) actually succeeds, closing the loop QA opened.
  run "$SCRIPT" workspaces --apply --only workspaces/cmo/skills/accuracy-protocol/SKILL.md
  [ "$status" -eq 0 ]
  grep -qF '/./workspaces/cmo/skills/accuracy-protocol/SKILL.md' "$RSYNC_CALLS"
}

@test "--only path outside the target subdir is rejected" {
  run "$SCRIPT" skills --only workspaces/cmo/SOUL.md
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'skills-all/'
  [ ! -s "$RSYNC_CALLS" ]
}

@test "--only rejects .. traversal even after a valid prefix" {
  run "$SCRIPT" skills --only skills-all/../scripts/foo.sh
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'traversal|invalid|\.\.'
  [ ! -s "$RSYNC_CALLS" ]
}

@test "--only rejects absolute paths" {
  run "$SCRIPT" skills --only /etc/passwd
  [ "$status" -ne 0 ]
  [ ! -s "$RSYNC_CALLS" ]
}
