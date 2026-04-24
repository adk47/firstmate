#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# lint-openclaw-config.sh
#
# Reject openclaw configs that declare a remote MCP server via
#   {"command": "npx", "args": ["mcp-remote", "<url>", ...]}
#
# Those entries are functional but dangerous: `npm exec mcp-remote`
# spawns a subprocess trio (npm → sh → node) that inherits the
# gateway's process group. Any reap-by-pgid strategy takes the
# whole gateway down — exactly what broke Clio on 2026-04-24.
#
# Every remote MCP server we've shipped today speaks streamable-HTTP
# natively, so the fix is a one-line config rewrite:
#   {"transport": "streamable-http", "url": "...", "headers": {...}}
#
# OpenClaw's bundle-mcp already handles that transport via
# @modelcontextprotocol/sdk's StreamableHTTPClientTransport — no
# subprocess, no leak, no pgid collision.
#
# Usage:  lint-openclaw-config.sh <config.json> [config.json ...]
# Exit:   0 if clean, 1 if any file has an offending entry, 2 on arg error
# ──────────────────────────────────────────────────────────────
set -euo pipefail

if (( $# == 0 )); then
  echo "usage: $0 <openclaw-config.json> [...]" >&2
  exit 2
fi

fail=0
for f in "$@"; do
  if [[ ! -f "$f" ]]; then
    echo "skip (not found): $f" >&2
    continue
  fi
  bad=$(jq -r '
    .mcp.servers // {}
    | to_entries[]
    | select(
        (.value.command == "npx" or .value.command == "npm")
        and ((.value.args // []) | any(. == "mcp-remote"))
      )
    | .key
  ' "$f" 2>/dev/null || true)
  if [[ -n "$bad" ]]; then
    echo "ERROR: $f contains mcp-remote stdio MCP server entries:" >&2
    echo "$bad" | sed 's/^/  - /' >&2
    fail=1
  fi
done

if (( fail )); then
  cat >&2 <<'EOF'

These entries leak subprocesses and share the gateway's process group;
any reaper (or crash-on-exit) kills the gateway. Rewrite to native
streamable-HTTP:

  {
    "transport": "streamable-http",
    "url": "https://host/mcp/<id>",
    "headers": { "x-auth-token": "..." }
  }

To rewrite a single live server in place:
  openclaw --profile <profile> mcp set "<Server Name>" '<new json>'
EOF
  exit 1
fi

exit 0
