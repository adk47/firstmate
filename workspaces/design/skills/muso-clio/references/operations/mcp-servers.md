# MCP Servers in OpenClaw

How MCP servers (NocoDB, Notion, GitMCP, etc.) are wired into the OpenClaw gateways used by Slack/Clio.

> **2026-04-22 update:** This runbook previously described an `mcporter` CLI wrapper. OpenClaw 2026.4.15+ has **native** MCP support via `openclaw mcp` — no separate CLI or config file needed. The old mcporter instructions were superseded and have been removed.

## Mental model

- MCP servers are configured **per profile** inside the profile's `openclaw.json`, under the `mcp` / `mcpServers` key.
- Each profile has its own config file: `/root/.openclaw-main/openclaw.json`, `/root/.openclaw-edge/openclaw.json`, `/root/.openclaw-dev/openclaw.json`.
- All agents on a profile share the MCP server list for that profile — there is no per-agent scoping at this layer.
- The gateway loads MCP config at start; **new sessions** pick up config changes, but in-flight sessions do not.

## Commands

Use `openclaw mcp` (add `--profile <name>` to target a non-default profile):

```bash
# List configured MCP servers
openclaw --profile main mcp list

# Show one server's config (or the full mcp config with no arg)
openclaw --profile main mcp show "NocoDB Base - Intelligence"

# Add / overwrite a server
openclaw --profile main mcp set "NocoDB Base - Intelligence" '{
  "command": "npx",
  "args": [
    "mcp-remote",
    "https://app.nocodb.com/mcp/<base-id>",
    "--header",
    "xc-mcp-token: <token>"
  ]
}'

# Remove a server
openclaw --profile main mcp unset "NocoDB Base - Intelligence"

# Bridge OpenClaw channels out over MCP stdio (rarely used day-to-day)
openclaw --profile main mcp serve
```

`openclaw mcp set` **overwrites** the named entry and writes a timestamped backup under the profile directory (look for `openclaw.json.bak*`). Always back up the config yourself first too when editing prod:

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
cp /root/.openclaw-main/openclaw.json "/root/.openclaw-main/openclaw.json.bak-${TS}-pre-<reason>"
```

## Server types

### Remote HTTP MCP bridged over stdio (`npx mcp-remote`)

Use for third-party hosted MCPs that expose an HTTP endpoint and a header-based token (NocoDB, some SaaS MCPs).

```json
{
  "command": "npx",
  "args": [
    "mcp-remote",
    "https://provider.example/mcp/<id>",
    "--header",
    "<auth-header>: <token>"
  ]
}
```

Pros: no local install beyond `npx`. Cons: cold-start latency on first call per session.

### Stdio MCP via a local CLI (e.g. `uvx context7-mcp`)

Use when the provider publishes an MCP CLI you run directly.

```json
{
  "command": "uvx",
  "args": ["context7-mcp"]
}
```

### Hosted OAuth MCP (e.g. Notion)

Hosted OAuth MCPs need an interactive browser flow to mint a token. For headless gateway hosts, complete OAuth on a workstation and copy the token cache onto the gateway host. Consult the provider's MCP docs for the token cache path.

## Propagating a config change live

The gateway **does not hot-reload** the MCP config. After `openclaw mcp set/unset`:

1. New sessions (triggered via Slack mention, cron, etc.) pick up the change.
2. In-flight sessions keep the old tool list until they end.
3. If you need an immediate refresh across all sessions:
   ```bash
   systemctl restart openclaw-gateway-main   # (or -edge / -dev)
   ```
   This disrupts any live Slack conversation — prefer "let new sessions pick it up" unless the MCP is blocking time-critical work.

## Verifying from the gateway

```bash
# From the host
openclaw --profile main mcp list
openclaw --profile main mcp show "<server name>"

# From a Slack DM with the agent, after a new session starts
@cmo which MCP tools do you have access to?
```

## Security notes

- `openclaw mcp set` writes the raw JSON (including any bearer tokens / headers) into the profile's `openclaw.json`. That file is world-readable to `root` on the gateway host — do **not** commit it. Rotate tokens if the config file is leaked.
- `openclaw.json` is not in git; only the repo templates + skill docs are.
- For private GitHub repo access, prefer the built-in OpenClaw `github` skill (uses `gh` CLI under the gateway user) over hosted GitMCP, which cannot reach private repos.

## Troubleshooting

- **`openclaw mcp list` returns "No MCP servers configured"** — the profile's `openclaw.json` has no `mcp`/`mcpServers` key. Run `openclaw --profile <name> mcp set` or check you're targeting the right profile with `--profile`.
- **Agent can't see the tool after config change** — most likely the session was started before the config change. Start a new session (re-@mention in Slack or wait for the next cron run).
- **`npx mcp-remote` fails on cold start** — check outbound HTTPS reachability from the gateway host to the MCP provider; hosted MCPs often require IP allowlisting.
