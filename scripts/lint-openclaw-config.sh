#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# lint-openclaw-config.sh
#
# Reject openclaw configs that would end up spawning a local
# `mcp-remote` subprocess to bridge a remote HTTP MCP server.
#
# Those entries are functional but dangerous: `npm exec mcp-remote`
# (or any shell that eventually invokes it) spawns a subprocess
# trio (npm → sh → node) that inherits the gateway's process
# group. Any reap-by-pgid strategy takes the whole gateway down —
# exactly what broke Clio on 2026-04-24.
#
# Every remote MCP server we've shipped today speaks streamable-HTTP
# natively, so the fix is a one-line config rewrite:
#   {"transport": "streamable-http", "url": "...", "headers": {...}}
#
# OpenClaw's bundle-mcp already handles that transport via
# @modelcontextprotocol/sdk's StreamableHTTPClientTransport — no
# subprocess, no leak, no pgid collision.
#
# Matching rule (broad on purpose; the leak class cares about the
# binary eventually invoked, not the launcher):
#   - Entry has a non-empty `command` (it's stdio, not HTTP), AND
#   - Its `transport` is not one of {sse, streamable-http}, AND
#   - EITHER the `command` basename is exactly `mcp-remote`,
#     OR any element of `args` contains the token `mcp-remote`
#     (catches `npx mcp-remote`, `mcp-remote@1.0`,
#     `/path/to/mcp-remote`, `bash -c 'npx mcp-remote ...'`, etc.)
#
# Usage:  lint-openclaw-config.sh <config.json> [config.json ...]
# Exit:   0 clean, 1 offending entry found, 2 arg/dependency error,
#         3 malformed/unreadable config file
# ──────────────────────────────────────────────────────────────
set -euo pipefail

if (( $# == 0 )); then
  echo "usage: $0 <openclaw-config.json> [...]" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "lint-openclaw-config: jq is required but not on PATH" >&2
  exit 2
fi

# The jq program is shared between the "is this file parseable JSON"
# check (`jq empty`) and the match rule.
# shellcheck disable=SC2016  # intentional: single-quoted jq program
read -r -d '' MATCH_RULE <<'JQ' || true
.mcp.servers // {}
| to_entries[]
| select(
    .value as $v
    | ($v.command // "") != ""
    and ($v.transport != "sse")
    and ($v.transport != "streamable-http")
    and (
      (($v.command // "") | split("/") | last == "mcp-remote")
      or (($v.args // []) | map(tostring) | any(test("(^|[/ ])mcp-remote([@ ]|$)")))
    )
  )
| .key
JQ

fail=0
parse_fail=0
for f in "$@"; do
  if [[ ! -f "$f" ]]; then
    echo "lint-openclaw-config: skip (not found): $f" >&2
    continue
  fi
  if ! jq empty "$f" >/dev/null 2>&1; then
    echo "ERROR: $f is not valid JSON (jq refused to parse)" >&2
    parse_fail=1
    continue
  fi
  bad=$(jq -r "$MATCH_RULE" "$f")
  if [[ -n "$bad" ]]; then
    echo "ERROR: $f contains entries that would spawn mcp-remote:" >&2
    # shellcheck disable=SC2001  # newline-delimited input, parameter expansion doesn't help
    echo "$bad" | sed 's/^/  - /' >&2
    fail=1
  fi
done

if (( parse_fail )); then
  echo >&2
  echo "One or more configs failed JSON parse; refusing to lint." >&2
  exit 3
fi

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

Example (NocoDB):
  openclaw --profile main mcp set "NocoDB Base - B2B ADs intelligence" '{
    "transport": "streamable-http",
    "url": "https://app.nocodb.com/mcp/<id>",
    "headers": {"xc-mcp-token": "<token>"}
  }'
EOF
  exit 1
fi

exit 0
