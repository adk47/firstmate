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
# or nothing when openclaw is missing/unparseable. Never fails the caller.
openclaw_runtime_version() {
  openclaw --version 2>/dev/null | awk 'NR==1 {print $2}' || true
}
