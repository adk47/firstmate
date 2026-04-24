# MCP Servers in OpenClaw

How MCP servers (NocoDB, Notion, GitMCP, etc.) are wired into the OpenClaw gateways used by Slack/Clio.

> **2026-04-22 update:** This runbook previously described an `mcporter` CLI wrapper. OpenClaw 2026.4.15+ has **native** MCP support via `openclaw mcp` — no separate CLI or config file needed. The old mcporter instructions were superseded and have been removed.
>
> **2026-04-24 update:** Remote HTTP MCP servers MUST be configured with `transport: "streamable-http"` (native) rather than the legacy `npx mcp-remote` stdio bridge. The stdio bridge leaked subprocesses that shared the gateway's process group, so any reap-by-pgid took the gateway down (Clio outage 2026-04-24). `deploy.sh` rejects mcp-remote entries via `scripts/lint-openclaw-config.sh`.

## Mental model

- MCP servers are configured **per profile** inside the profile's `openclaw.json`, under the `mcp.servers` key.
- Each profile has its own config file: `/root/.openclaw-main/openclaw.json`, `/root/.openclaw-edge/openclaw.json`, `/root/.openclaw-dev/openclaw.json`.
- All agents on a profile share the MCP server list for that profile — there is no per-agent scoping at this layer.
- The gateway loads MCP config at start; **new sessions** pick up config changes, but in-flight sessions do not.
- `deploy.sh` preserves live `.mcp.servers` across deploys, so server-side registrations (like NocoDB's auth token) don't need to live in the repo.

## Commands

Use `openclaw mcp` (add `--profile <name>` to target a non-default profile):

```bash
# List configured MCP servers
openclaw --profile main mcp list

# Show one server's config (or the full mcp config with no arg)
openclaw --profile main mcp show "NocoDB Base - Intelligence"

# Add / overwrite a server
openclaw --profile main mcp set "NocoDB Base - Intelligence" '{
  "transport": "streamable-http",
  "url": "https://app.nocodb.com/mcp/<base-id>",
  "headers": { "xc-mcp-token": "<token>" }
}'

# Remove a server
openclaw --profile main mcp unset "NocoDB Base - Intelligence"

# Bridge OpenClaw channels out over MCP stdio (rarely used day-to-day)
openclaw --profile main mcp serve
```

`openclaw mcp set` **overwrites** the named entry and writes a timestamped backup under the profile directory (look for `openclaw.json.bak*`). Always back up the config yourself first too when editing prod:

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
cp /root/.openclaw-main/openclaw.json "/root/hydra-hotpatch-backups/openclaw.main.${TS}.json"
```

## Server types

### Remote HTTP MCP (default for third-party hosted MCPs)

Use for any hosted MCP that exposes a streamable-HTTP (or SSE) endpoint — NocoDB, most SaaS MCPs. The gateway connects directly via the SDK's `StreamableHTTPClientTransport`; no subprocess is spawned.

```json
{
  "transport": "streamable-http",
  "url": "https://provider.example/mcp/<id>",
  "headers": { "<auth-header>": "<token>" }
}
```

If the provider only speaks plain SSE, use `"transport": "sse"` instead. Same field shape; the SDK picks the right transport.

**Do not use `npx mcp-remote`.** It is an older stdio↔HTTP shim that leaks subprocesses sharing the gateway's process group. The deploy lint will reject it.

### Stdio MCP via a local CLI (e.g. `uvx context7-mcp`)

Use when the provider publishes an MCP CLI you run directly — the subprocess is the MCP server itself, not a bridge to a remote one, so the pgid problem doesn't apply.

```json
{
  "command": "uvx",
  "args": ["context7-mcp"]
}
```

### Hosted OAuth MCP (e.g. Notion)

Hosted OAuth MCPs need an interactive browser flow to mint a token. For headless gateway hosts, complete OAuth on a workstation and copy the token cache onto the gateway host. Consult the provider's MCP docs for the token cache path. If the provider's OAuth layer only works through `mcp-remote`'s auth flow, that's the one exception where a temporary mcp-remote entry is acceptable — file an upstream issue on the provider asking for a static-token streamable-HTTP alternative and remove the mcp-remote entry as soon as they ship one.

## Propagating a config change live

The gateway detects config changes via file-system watch and will either hot-reload or schedule a restart (`[reload] config change requires gateway restart ... deferring until N task run(s) complete`). After `openclaw mcp set/unset`:

1. Small changes (e.g. adding a header) can hot-reload.
2. Transport/URL changes force a restart — the gateway drains in-flight tasks first.
3. For an immediate forced refresh:
   ```bash
   systemctl restart openclaw-gateway-main   # (or -edge / -dev)
   ```
   ~15s of downtime; disrupts any live Slack conversation.

## Verifying from the gateway

```bash
# From the host
openclaw --profile main mcp list
openclaw --profile main mcp show "<server name>"

# Confirm no legacy stdio bridges leaked back in
scripts/lint-openclaw-config.sh /root/.openclaw-*/openclaw.json

# Confirm there are NO mcp-remote processes parented to the gateway
ps -eo pid,pgid,comm,args --no-headers | grep -F mcp-remote | grep -v grep || echo "(clean)"

# From a Slack DM with the agent, after a new session starts
@cmo which MCP tools do you have access to?
```

## Security notes

- `openclaw mcp set` writes the raw JSON (including any bearer tokens / headers) into the profile's `openclaw.json`. That file is readable to `root` on the gateway host — do **not** commit it. Rotate tokens if the config file is leaked.
- Repo templates (`openclaw-main.json` et al.) intentionally have an empty `mcp.servers`; `deploy.sh` preserves the live list so tokens stay server-side.
- For private GitHub repo access, prefer the built-in OpenClaw `github` skill (uses `gh` CLI under the gateway user) over hosted GitMCP, which cannot reach private repos.

## Troubleshooting

- **`openclaw mcp list` returns "No MCP servers configured"** — the profile's `openclaw.json` has no `mcp.servers` entries. Run `openclaw --profile <name> mcp set` or check you're targeting the right profile with `--profile`.
- **`bundle-mcp: skipped server "X" because ...`** in the gateway log — the config shape didn't match either stdio or HTTP. Common cause: missing `url` for an HTTP server, or a `command` that's empty/invalid. Run `openclaw --profile <name> mcp show "X"` and compare against the JSON shapes above.
- **Agent can't see the tool after config change** — most likely the session was started before the config reload. Start a new session (re-@mention in Slack or wait for the next cron run).
- **Deploy fails with `openclaw config lint: ... mcp-remote stdio entries`** — someone committed or hot-registered a legacy `{"command": "npx", "args": ["mcp-remote", ...]}` entry. Rewrite it with `openclaw mcp set` using the streamable-HTTP shape above.
- **Gateway RAM climbs steadily** — historically caused by accumulated `mcp-remote` orphans. With native streamable-HTTP there are no subprocesses, so this should not recur; if it does, the cause is elsewhere (check `ps --forest` under the gateway unit).
