#!/usr/bin/env bash
# check-caroline-inventory.sh — CI gate for the Caroline Jev-router inventory
# (docs/designs/2026-09-22-jev-caroline-router.md, section A).
#
# Regenerate-and-diff, like the other check-*.sh scripts in this repo:
# scripts/gen-caroline-inventory.sh is deterministic, so a clean tree
# regenerates byte-identical files. A diff here means the checked-in
# plugins/intercom/src/caroline-inventory.json and/or caroline-questions.json
# are stale relative to their sources (plugins/support-tools/src/tools/*.ts,
# workspaces/support/TOOLS.md, workspaces/support/skills/*/SKILL.md,
# support-action-router.ts).
#
# Exit codes:
#   0 — both files match the generator's output (WARNs, e.g. an undocumented
#       tool, are printed but not fatal)
#   1 — drift detected: at least one file differs
#   2 — script-level error (generator failed, missing source file)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="${REPO_ROOT}/scripts/gen-caroline-inventory.sh"
CHECKED_IN_DIR="${REPO_ROOT}/plugins/intercom/src"

[[ -x "$GEN" ]] || { echo "FATAL: $GEN not found or not executable" >&2; exit 2; }
for f in "${CHECKED_IN_DIR}/caroline-inventory.json" "${CHECKED_IN_DIR}/caroline-questions.json"; do
  [[ -f "$f" ]] || { echo "FATAL: $f not found" >&2; exit 2; }
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-caroline-inventory.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! "$GEN" --out-dir "$WORK_DIR"; then
  echo "FATAL: gen-caroline-inventory.sh failed" >&2
  exit 2
fi

DRIFT=0
for name in caroline-inventory.json caroline-questions.json; do
  if ! diff -u "${CHECKED_IN_DIR}/${name}" "${WORK_DIR}/${name}"; then
    DRIFT=1
  fi
done

if (( DRIFT != 0 )); then
  echo "" >&2
  echo "FAIL: ${CHECKED_IN_DIR#${REPO_ROOT}/}/{caroline-inventory,caroline-questions}.json are stale." >&2
  echo "run scripts/gen-caroline-inventory.sh and commit" >&2
  exit 1
fi

echo "OK: caroline-inventory.json and caroline-questions.json match scripts/gen-caroline-inventory.sh."
exit 0
