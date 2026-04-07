#!/usr/bin/env bash
# Activate .githooks/ as this repo's hooks directory.
# Idempotent — safe to run multiple times.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

git config core.hooksPath .githooks

# chmod failures must surface — pre-commit not being executable is the
# exact failure mode this script exists to prevent. No `2>/dev/null || true`.
if compgen -G ".githooks/*" >/dev/null; then
  chmod +x .githooks/*
fi

echo "✓ git hooks activated (.githooks/)"
echo "  run: git config --get core.hooksPath   # to verify"
