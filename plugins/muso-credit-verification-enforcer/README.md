# muso-credit-verification-enforcer

openclaw plugin that supports grounded credit-verification on hydra.
The approve gate itself lives in the bash layer (`muso-admin-api.sh`);
this plugin handles what the openclaw hook bus reliably delivers.

## Hooks

- `mark-cv-session` (`inbound_claim`) — marks a session as
  credit-verification when it arrives on the CV channel.
- `redirect-web-search` (`before_tool_call`) — blocks `web_search` in the
  credit-verification context and redirects the agent to use `browser` with
  a search engine URL.
- `cleanup-session-state` (`session_end`) — unmarks the CV session so the
  in-memory set doesn't grow unbounded.

## Approve gate

The deterministic approve gate (content-match, browser-only, Tier 1
evidence) is enforced in `muso-admin-api.sh`, not in this plugin. See
`workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh`.

## Test

`pnpm install && pnpm test`
