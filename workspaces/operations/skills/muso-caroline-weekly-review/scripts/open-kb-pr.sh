#!/usr/bin/env bash
# Open ONE PR aggregating ALL approved KB-gap clusters.
# Usage: open-kb-pr.sh <approved-clusters.json> <conversations.jsonl>
#
# Contract:
#   - Validates clusters before touching any git state.
#   - Creates ONE branch, applies all edits, runs .githooks/pre-commit, commits,
#     opens ONE PR with reviewer nsollazzo.
#   - Safe-restore on ANY failure: reset --hard + clean -fd + checkout base + delete branch.

set -euo pipefail

CLUSTERS="${1:?clusters.json required}"
CONVERSATIONS="${2:?conversations.jsonl required}"

# Mechanical opt-in gate. Default OFF: PRs only open when the operator
# explicitly sets OPS_CAROLINE_REVIEW_PR_OPEN=1. Prevents accidental auto-PRs
# during shadow runs or before the cron is fully trusted.
if [ "${OPS_CAROLINE_REVIEW_PR_OPEN:-0}" != "1" ]; then
  echo "open-kb-pr: skipped — OPS_CAROLINE_REVIEW_PR_OPEN not set to 1" >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Acquire a Hydra checkout to work in. The cron's operations workspace is NOT a
# repo checkout, so do NOT assume cwd is one (it was: `git rev-parse
# --show-toplevel` would fail or point at the wrong repo when PR_OPEN=1).
# Use an explicitly provided checkout (CAROLINE_KB_REPO_DIR — tests, or a known
# server checkout) or clone a fresh shallow copy that we own and clean up.
TMP_CLONE=""
if [ -n "${CAROLINE_KB_REPO_DIR:-}" ]; then
  REPO_ROOT=$(cd "$CAROLINE_KB_REPO_DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "open-kb-pr: CAROLINE_KB_REPO_DIR is not a git checkout: ${CAROLINE_KB_REPO_DIR}" >&2; exit 1; }
else
  TMP_CLONE=$(mktemp -d -t caroline-kb-repo-XXXXXX)
  if ! gh repo clone Muso-AI/hydra "$TMP_CLONE" -- --depth 1 >/dev/null 2>&1; then
    echo "open-kb-pr: failed to clone Muso-AI/hydra into $TMP_CLONE" >&2
    rm -rf "$TMP_CLONE"
    exit 1
  fi
  REPO_ROOT="$TMP_CLONE"
  # git clone does not copy the source repo's local identity, and the host may
  # have no global identity (the cron runs as a service user) — set a
  # deterministic bot identity so `git commit` cannot fail "Author identity
  # unknown". Only on the throwaway clone; an explicit CAROLINE_KB_REPO_DIR
  # checkout keeps its own identity (overriding it could hijack, e.g., the
  # release checkout's tag identity).
  git -C "$REPO_ROOT" config user.name "Caroline Weekly Review"
  git -C "$REPO_ROOT" config user.email "ops@muso.ai"
fi
cd "$REPO_ROOT"
BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
TODAY=$(date -u +%Y-%m-%d)
AUTO_BRANCH="auto/caroline-kb-review-$TODAY"

# State — must be declared before the trap.
PR_BODY_FILE=""
CLUSTERS_BLOCK_FILE=""
AUTO_BRANCH_CREATED=0
REMOTE_PUSHED=0
PR_CREATED=0

safe_restore() {
  set +e
  git reset --hard >/dev/null 2>&1
  git clean -fd >/dev/null 2>&1
  if git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
    git checkout "$BASE_BRANCH" >/dev/null 2>&1
  fi
  git branch -D "$AUTO_BRANCH" >/dev/null 2>&1
  set -e
}

cleanup_temp_files() {
  [ -n "$PR_BODY_FILE" ] && rm -f "$PR_BODY_FILE"
  [ -n "$CLUSTERS_BLOCK_FILE" ] && rm -f "$CLUSTERS_BLOCK_FILE"
}

on_exit() {
  local rc=$?
  # If the branch was pushed but no PR was opened (post-push failure), delete the
  # remote branch so a same-day retry from a fresh clone is not blocked by a
  # stale non-fast-forward auto branch. Runs before the temp clone is removed so
  # the push --delete has a repo to run from.
  if [ "$REMOTE_PUSHED" -eq 1 ] && [ "$PR_CREATED" -eq 0 ]; then
    git push origin --delete "$AUTO_BRANCH" >/dev/null 2>&1 || true
  fi
  # A throwaway clone needs no worktree restore — just delete it. An in-place
  # checkout (CAROLINE_KB_REPO_DIR) must be restored: reset/clean/checkout base/
  # delete branch, on both success (local auto branch no longer needed) and
  # failure paths.
  if [ -n "$TMP_CLONE" ]; then
    rm -rf "$TMP_CLONE"
  elif [ "$AUTO_BRANCH_CREATED" -eq 1 ]; then
    safe_restore
  fi
  cleanup_temp_files
  exit "$rc"
}
trap on_exit EXIT

# Worktree must be clean before we touch anything
if ! git diff --quiet || ! git diff --cached --quiet \
     || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  echo "open-kb-pr: worktree not clean — aborting" >&2
  exit 1
fi

# Validate clusters before doing anything destructive
"$SCRIPT_DIR/validate-clusters.sh" "$CLUSTERS" "$CONVERSATIONS" "$REPO_ROOT" >&2 \
  || { echo "open-kb-pr: validate-clusters rejected one or more clusters" >&2; exit 1; }

# Refuse to proceed if branch already exists
if git show-ref --verify --quiet "refs/heads/$AUTO_BRANCH"; then
  echo "open-kb-pr: branch $AUTO_BRANCH already exists" >&2
  exit 1
fi
git checkout -b "$AUTO_BRANCH" >/dev/null
AUTO_BRANCH_CREATED=1

# Apply each cluster's insertion via python (multi-line safe)
python3 - "$CLUSTERS" "$REPO_ROOT" <<'PY' || { echo "open-kb-pr: apply failed" >&2; exit 1; }
import json, os, re, sys
clusters_path, repo_root = sys.argv[1], sys.argv[2]
data = json.load(open(clusters_path))
for c in data["clusters"]:
    target = os.path.join(repo_root, c["target_path"])
    with open(target) as f:
        content = f.read()
    anchor = c["anchor"]
    insertion = c["insertion"]
    if anchor not in content:
        # No anchor -- append under a generated section header
        content = content.rstrip() + "\n\n" + anchor + "\n\n" + insertion + "\n"
    else:
        # Insert immediately after the anchor line plus its trailing blank
        pattern = re.escape(anchor) + r"\n+"
        content = re.sub(pattern, lambda m: m.group(0) + insertion + "\n\n", content, count=1)
    with open(target, "w") as f:
        f.write(content)
PY

# Stage all changes
git add -A

# Run the repo's pre-commit hook against the staged state
if [ -x "$REPO_ROOT/.githooks/pre-commit" ]; then
  if ! bash "$REPO_ROOT/.githooks/pre-commit"; then
    echo "open-kb-pr: pre-commit hook failed — branch restored" >&2
    exit 1
  fi
fi

# Build commit message body listing all cluster topics
COMMIT_BODY=$(jq -r '.clusters | map("- " + .topic + " (N=" + (.unique_customers|tostring) + ", IDs: " + (.conversation_ids | join(", ")) + ")") | join("\n")' "$CLUSTERS")

if ! git commit -q -m "chore(support): Caroline KB updates from week of $TODAY

Auto-generated by muso-caroline-weekly-review.

Clusters:
$COMMIT_BODY

Co-Authored-By: Caroline Weekly Review <ops@muso.ai>"; then
  echo "open-kb-pr: git commit failed (likely no changes after edits)" >&2
  exit 1
fi

# Build PR body from template
PR_BODY_FILE=$(mktemp)
CLUSTERS_BLOCK=$(jq -r '.clusters | map(
  "### " + .topic + "\n" +
  "- Unique contacts: " + (.unique_customers|tostring) + "\n" +
  "- Conversation IDs: " + (.conversation_ids | join(", ")) + "\n" +
  "- Caroline'\''s response pattern: " + .response_pattern + "\n" +
  "- Target: `" + .target_path + "`\n" +
  "- See the diff for the proposed prose."
) | join("\n\n")' "$CLUSTERS")
WEEK_OF=$(jq -r '.week_of' "$CLUSTERS")
CLUSTER_COUNT=$(jq -r '.clusters | length' "$CLUSTERS")

CLUSTERS_BLOCK_FILE=$(mktemp)
printf '%s' "$CLUSTERS_BLOCK" > "$CLUSTERS_BLOCK_FILE"
python3 - "$SCRIPT_DIR/../references/pr-template.md" "$CLUSTERS_BLOCK_FILE" "$WEEK_OF" "$CLUSTER_COUNT" <<'PY' \
  | "$SCRIPT_DIR/redact-output.sh" \
  > "$PR_BODY_FILE"
import sys
tmpl_path, block_path, week_of, cluster_count = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(tmpl_path) as f:
    tmpl = f.read()
with open(block_path) as f:
    block = f.read()
out = tmpl.replace("{{WEEK_OF}}", week_of).replace("{{CLUSTER_COUNT}}", cluster_count).replace("{{CLUSTERS_BLOCK}}", block)
print(out, end="")
PY

if ! git push -u origin "$AUTO_BRANCH" >/dev/null 2>&1; then
  echo "open-kb-pr: git push failed" >&2
  exit 1
fi
REMOTE_PUSHED=1

if ! PR_URL=$(gh pr create \
  --title "chore(support): Caroline KB updates from week of $TODAY" \
  --body-file "$PR_BODY_FILE" \
  --reviewer nsollazzo \
  --base "$BASE_BRANCH" \
  --head "$AUTO_BRANCH" 2>&1); then
  echo "open-kb-pr: gh pr create failed: $PR_URL" >&2
  exit 1
fi
PR_CREATED=1

echo "$PR_URL"
