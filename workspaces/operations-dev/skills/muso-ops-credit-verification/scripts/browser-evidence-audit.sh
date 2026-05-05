#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_DIR="$(printf '%s\n' "$SCRIPT_DIR" | sed 's#workspaces/operations-dev/skills/#workspaces/operations/skills/#')"
exec bash "$CANONICAL_DIR/browser-evidence-audit.sh" "$@"
