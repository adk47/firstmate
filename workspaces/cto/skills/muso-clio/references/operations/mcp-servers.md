# MCP Servers (Notion, GitMCP, etc.) in OpenClaw

This runbook describes how to connect **MCP servers** (like **Notion MCP** and **GitMCP**) to the OpenClaw gateway used by Slack.

## Mental model

- OpenClaw does not ship a built-in Notion integration today (Notion access is typically via MCP).
- OpenClaw can use the `mcporter` skill to call MCP servers.
- `mcporter` finds MCP servers from its config file (`mcpServers`).

## What needs to be installed on the OpenClaw host

1) **The `mcporter` skill is enabled** in OpenClaw.

2) **The `mcporter` CLI is installed** on the host and present on `PATH`.

## What config files need to exist (and where)

### MCP server definitions

Create a `mcporter` config file on the OpenClaw host:

- `~/.mcporter/mcporter.json` (recommended; system-wide default)

Example:

```json
{
  "mcpServers": {
    "notion": {
      "baseUrl": "https://mcp.notion.com/mcp",
      "auth": "oauth",
      "oauthRedirectUrl": "http://localhost:0/callback"
    }
  },
  "imports": []
}
```

Notes:
- Use `imports: []` if you want fully explicit configuration (no auto-import from other MCP clients).
- If you prefer a dedicated config path, set `MCPORTER_CONFIG` (see “Wiring into OpenClaw”).
- `auth: "oauth"` is required for hosted Notion MCP; without it, `mcporter auth notion` will not start the browser flow.
- If you see `InvalidGrantError: Invalid redirect URI` during Notion OAuth, set `oauthRedirectUrl` to a `localhost` loopback URL (some providers reject `127.0.0.1`):
  - Recommended: `"oauthRedirectUrl": "http://localhost:0/callback"` (dynamic port)

### Config resolution (important for the gateway)

`mcporter` looks for config in these places (in priority order):

- Project config: `~/config/mcporter.json`
- System config: `~/.mcporter/mcporter.json`

The OpenClaw gateway’s working directory is typically `/`, so do **not** rely on `./config/mcporter.json` on the gateway host; prefer `~/.mcporter/mcporter.json` or set `MCPORTER_CONFIG`.

### OAuth token cache (Notion hosted MCP)

If you use Notion’s hosted MCP, OAuth tokens are cached by `mcporter` under:

- `~/.mcporter/` (server-specific subfolders)

In headless production environments, you can complete OAuth on a workstation and then copy the token cache directory onto the gateway host (same OS user that runs OpenClaw).

## Setup steps (host)

1) Install/enable the `mcporter` skill in OpenClaw (Control UI → Skills).

2) Install `mcporter` CLI on the gateway host.

3) Create `~/.mcporter/mcporter.json` with your servers (example above).

4) Verify the gateway can see the servers:

```bash
mcporter list
mcporter list notion --schema
```

5) If using Notion hosted MCP, complete OAuth once:

```bash
mcporter auth notion
```

If you expect to take longer than 60 seconds to approve in the browser, increase the timeout:

```bash
mcporter --oauth-timeout 600000 auth notion
```

6) Start a new OpenClaw session (or restart the gateway) so the updated skill/tool environment is picked up.

## Wiring into OpenClaw (recommended for production)

To ensure `mcporter` always uses the intended config file, inject:

- `MCPORTER_CONFIG=/etc/openclaw/mcporter.json` (or another secure path)

Where to inject depends on your deployment:

- **systemd:** set environment in the service unit (or an `EnvironmentFile=`).
- **Docker/ECS/EKS:** inject env vars via task definition / Kubernetes Secret.
- **OpenClaw config:** set per-skill env at `skills.entries.mcporter.env` (if you want the gateway to inject env only for agent runs).

## Recommended server entries

### GitMCP (read-only repo docs/code)

- URL format: `https://gitmcp.io/<owner>/<repo>`
- No secrets required.
- **Important:** Hosted GitMCP can only read repos that are accessible without GitHub authentication. For private repos, use the OpenClaw `github` skill (below) or self-host a Git MCP server inside your environment.

### Private GitHub repos (recommended: OpenClaw `github` skill via `gh`)

If you need access to **private** GitHub repos from Slack/OpenClaw, prefer the built-in OpenClaw `github` skill which uses the `gh` CLI on the gateway host.

Host prerequisites:
- Install `gh` (macOS + Homebrew): `brew install gh`
- Ensure the gateway user is authenticated: `gh auth status -h github.com`

Example commands (from the gateway host):
```bash
gh repo view Muso-AI/customer-api-mcp --json name,isPrivate,url
gh search code "mcpServers" --repo Muso-AI/customer-api-mcp --limit 20
```

### Notion MCP (recommended: hosted)

- URL: `https://mcp.notion.com/mcp`
- Requires OAuth once per gateway identity.

### Notion MCP (self-hosted)

Use this when you need token-based auth (non-interactive) and stricter control. In that model:
- You host a Notion MCP server inside your environment.
- The MCP server uses a Notion integration token.
- OpenClaw calls *your* MCP URL instead of `https://mcp.notion.com/mcp`.

## Troubleshooting

If `mcporter list` reports “No MCP servers configured”, it means the gateway host does not have a `mcporter` config file in any of the expected locations, and no imports produced servers.

Checklist:
- Confirm the OpenClaw host user running the gateway has `~/.mcporter/mcporter.json`.
- Confirm `mcporter` exists on `PATH`.
- If using `MCPORTER_CONFIG`, confirm the gateway process environment includes it.
- If using Notion hosted MCP, confirm OAuth was completed (`mcporter auth notion`) and the token cache exists.
