#!/usr/bin/env bats
# Tests for scripts/qa-clean-merge-scratch.sh — removes stray review scratch left
# directly under workspaces/qa/ on merge, WITHOUT ever deleting legit qa workspace
# state. "Legit" = tracked at repo HEAD OR matched by the depth-1-file subset of
# deploy.sh's RSYNC_EXCLUDES (e.g. the untracked-but-real IDENTITY.md/HEARTBEAT.md).
# Only never-tracked, never-excluded depth-1 FILES (the class that reds the deploy
# pre-flight — cf. scripts/lib/classify-deletions.sh) are removed.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-clean-merge-scratch.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR

  # A throwaway git repo standing in for the merged checkout: it tracks the 5 qa
  # seed files exactly as the real repo does (git ls-files workspaces/qa/ == those).
  export REPO_ROOT="$TEST_TMPDIR/repo"
  mkdir -p "$REPO_ROOT/workspaces/qa"
  for f in AGENTS.md MEMORY.md SOUL.md TOOLS.md USER.md; do
    echo "seed $f" > "$REPO_ROOT/workspaces/qa/$f"
  done
  git -C "$REPO_ROOT" init -q
  git -C "$REPO_ROOT" config user.email t@t.t
  git -C "$REPO_ROOT" config user.name t
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" commit -qm seed

  # A throwaway TARGET standing in for /opt/hydra/workspaces/qa on node-8.
  export TARGET="$TEST_TMPDIR/live"
  mkdir -p "$TARGET"
  export REL_PREFIX="workspaces/qa"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "removes stray scratch, keeps tracked seeds + untracked-but-excluded runtime + subdirs" {
  # Tracked seeds (some also runtime-excluded).
  for f in AGENTS.md MEMORY.md SOUL.md TOOLS.md USER.md; do echo x > "$TARGET/$f"; done
  # Untracked but legit (RSYNC_EXCLUDES depth-1 files).
  echo x > "$TARGET/IDENTITY.md"
  echo x > "$TARGET/HEARTBEAT.md"
  echo x > "$TARGET/write-activity.log"
  echo x > "$TARGET/TOOLS.md.bak-20260101T000000Z"
  echo x > "$TARGET/.env"
  # Tmp-marked scratch — excluded by deploy.sh's workspaces/*/*tmp* glob, so this
  # cleanup must KEEP it (lockstep with RSYNC_EXCLUDES). All three shapes the one
  # '*tmp*' KEEP glob subsumes must survive: .tmp- prefix (#690), tmp_ prefix (QA),
  # .tmp suffix (devops atomic-write).
  echo x > "$TARGET/.tmp-kubectl-catalog.sh"
  echo x > "$TARGET/tmp_pr704-review.md"
  echo x > "$TARGET/scratch.tmp"
  # Subdir runtime state — never the depth-1-file problem, must be untouched.
  mkdir -p "$TARGET/api-logs"; echo x > "$TARGET/api-logs/run.jsonl"
  # The actual (non-tmp) scratch: never tracked, never excluded → the only deletable class.
  echo x > "$TARGET/seven_days_ago"

  run "$SCRIPT" "$TARGET"
  [ "$status" -eq 0 ]

  # Only the non-tmp stray scratch is gone.
  [ ! -e "$TARGET/seven_days_ago" ]
  # Everything legit survives — tracked seeds, excluded runtime, AND tmp-marked scratch.
  for f in AGENTS.md MEMORY.md SOUL.md TOOLS.md USER.md IDENTITY.md HEARTBEAT.md \
           write-activity.log TOOLS.md.bak-20260101T000000Z .env \
           .tmp-kubectl-catalog.sh tmp_pr704-review.md scratch.tmp; do
    [ -e "$TARGET/$f" ] || { echo "WRONGLY DELETED: $f"; false; }
  done
  # Subdir + its file untouched.
  [ -e "$TARGET/api-logs/run.jsonl" ]
}

@test "no scratch present: no-op, exit 0, deletes nothing" {
  for f in AGENTS.md SOUL.md USER.md IDENTITY.md; do echo x > "$TARGET/$f"; done
  run "$SCRIPT" "$TARGET"
  [ "$status" -eq 0 ]
  for f in AGENTS.md SOUL.md USER.md IDENTITY.md; do [ -e "$TARGET/$f" ]; done
}

@test "missing TARGET dir: no-op, exit 0" {
  run "$SCRIPT" "$TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 0 ]
}

@test "fail-closed: REPO_ROOT not a git repo -> deletes NOTHING (can't tell seed from scratch)" {
  echo x > "$TARGET/seven_days_ago"
  echo x > "$TARGET/SOUL.md"
  REPO_ROOT="$TEST_TMPDIR/not-a-git-repo" run "$SCRIPT" "$TARGET"
  [ "$status" -eq 0 ]
  # Nothing removed, because without the tracked set a seed could be mistaken for scratch.
  [ -e "$TARGET/seven_days_ago" ]
  [ -e "$TARGET/SOUL.md" ]
}

@test "drift guard: KEEP globs cover every workspaces/*/ FILE exclude in deploy.sh" {
  # Extract deploy.sh's workspaces/*/<fileglob> excludes (single path component,
  # no trailing slash = a file, not a dir). Every one must be a KEEP glob, else a
  # future deploy.sh exclude would make this cleanup delete a newly-legit file.
  keep="$("$SCRIPT" --print-keep-globs)"
  mapfile -t deploy_file_excludes < <(
    grep -oE "exclude='workspaces/\*/[^/]+'" "$HYDRA_REPO/scripts/deploy.sh" \
      | sed -E "s/^exclude='workspaces\/\*\///; s/'$//" | sort -u
  )
  [ "${#deploy_file_excludes[@]}" -gt 0 ]   # sanity: we actually parsed some
  for g in "${deploy_file_excludes[@]}"; do
    grep -qxF -- "$g" <<<"$keep" || { echo "KEEP globs missing deploy.sh exclude: $g"; false; }
  done
}
