#!/usr/bin/env bash
# find-polluter.sh — bisect a test suite to find the file that pollutes shared
# state (the classic "passes alone, fails in the full run" bug).
#
# It runs each candidate test file in isolation, then runs a CHECK command.
# The first file after which CHECK fails (non-zero) is the polluter.
#
#   --check 'test ! -e .git'           -> file that leaves a stray .git behind
#   --check '<runner> victim.test.ts'  -> file whose side effects break `victim`
#
# Usage:
#   find-polluter.sh --dir <repo> --run '<run-template>' --check '<check-cmd>' <file> [file...]
#
#   --run template: a shell command that runs ONE test file. The token {} is
#     replaced with the file path, e.g.
#       --run 'npx vitest run {}'
#       --run 'pytest -q {}'
#
# It does NOT clean state between files — run from a clean tree and reset
# yourself between invocations (e.g. `git stash` / `git clean -fd`).
#
# Exit: 0 + prints the polluter path to stdout when found; 1 if no single file
#       fails the check (pollution is cross-file ordering, or not a test); 2 on
#       usage / baseline error.

set -euo pipefail

dir="" run="" check=""
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)   dir="$2";   shift 2 ;;
    --run)   run="$2";   shift 2 ;;
    --check) check="$2"; shift 2 ;;
    --)      shift; files+=("$@"); break ;;
    -*)      echo "unknown flag: $1" >&2; exit 2 ;;
    *)       files+=("$1"); shift ;;
  esac
done

if [[ -z "$dir" || -z "$run" || -z "$check" || ${#files[@]} -eq 0 ]]; then
  echo "usage: find-polluter.sh --dir <repo> --run '<cmd {}>' --check '<cmd>' <file>..." >&2
  exit 2
fi
[[ -d "$dir" ]] || { echo "not a directory: $dir" >&2; exit 2; }

cd "$dir"

# Baseline: the check must PASS in the clean tree, otherwise a later failure
# can't be attributed to any one file.
if ! bash -c "$check" >/dev/null 2>&1; then
  echo "baseline CHECK already fails in a clean tree — fix that first; nothing to bisect" >&2
  exit 2
fi

for f in "${files[@]}"; do
  cmd="${run//\{\}/$f}"
  echo "-> running: $cmd" >&2
  # A test failing is fine; we only care whether it polluted shared state.
  bash -c "$cmd" >/dev/null 2>&1 || true
  if ! bash -c "$check" >/dev/null 2>&1; then
    echo "POLLUTER: $f" >&2
    printf '%s\n' "$f"
    exit 0
  fi
done

echo "no single-file polluter found — likely cross-file ordering; bisect halves/pairs next" >&2
exit 1
