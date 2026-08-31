#!/usr/bin/env bash
# version-compare.sh — shared version helpers for the openclaw guard scripts.
# Introduced when the 2026.7.1 upgrade added the same sort -V idiom to four
# scripts at once (codex-version.sh, codex-auth-sync.sh, ensure-codex-auth.sh,
# deploy.sh) — extract-on-third-repetition rule.
#
# Sourced (not executed); no side effects, safe under set -euo pipefail.

# version_at_least <floor> <version> → 0 when <version> >= <floor> (inclusive).
# Uses GNU/BSD `sort -V` semantics: "2026.7" <= "2026.7.1" <= "2026.10".
version_at_least() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# openclaw_runtime_version → prints the installed runtime version ("2026.7.1")
# or nothing when openclaw is missing/unparseable/malformed. Never fails the
# caller. QA bot finding (PR #897 round 3): a non-empty but non-version-shaped
# token (e.g. "OpenClaw 2026.invalid") used to pass straight through to
# callers' `sort -V` comparisons, where the result is unspecified. Validating
# the shape HERE means every caller's existing empty-⇒-fail-loud/UNEVALUATED
# path already covers "malformed" too, for free.
openclaw_runtime_version() {
  local ver
  ver="$(openclaw --version 2>/dev/null | awk 'NR==1 {print $2}')" || true
  if [[ "$ver" =~ ^[0-9]{4}(\.[0-9]+)+$ ]]; then
    printf '%s' "$ver"
  fi
}
