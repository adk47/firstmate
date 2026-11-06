#!/usr/bin/env bash
# Fail when the legacy host credits.muso.ai appears outside .legacy-domain-allowlist.
# Customer-facing links use https://muso.ai/. MUS-31227 (parent MUS-31201).
# git grep exit 1 = no match = pass; any printed hit = fail.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
excludes=()
while IFS= read -r spec; do
  case "$spec" in
    ":(glob)"*) excludes+=(":(exclude,glob)${spec#:(glob)}") ;;
    *) excludes+=(":(exclude)$spec") ;;
  esac
done \
  < <(grep -vE '^\s*(#|$)' .legacy-domain-allowlist)
hits=$(git grep -nIE 'credits\.muso\.ai' -- . ':(exclude).legacy-domain-allowlist' ${excludes[@]+"${excludes[@]}"})
rc=$?
# rc 0 = hits, rc 1 = none; anything else (e.g. malformed pathspec) must not read as a pass.
if [ "$rc" -gt 1 ]; then
  echo "check-legacy-domain: git grep failed (rc=$rc); check .legacy-domain-allowlist syntax" >&2
  exit 2
fi
if [ -n "$hits" ]; then
  echo "$hits"
  echo "check-legacy-domain: legacy host credits.muso.ai found outside .legacy-domain-allowlist; use https://muso.ai/" >&2
  exit 1
fi
echo "check-legacy-domain: OK"
