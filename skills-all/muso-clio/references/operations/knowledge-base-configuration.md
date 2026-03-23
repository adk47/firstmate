# Knowledge Base Configuration (Current)

Last updated: 2026-02-01

This document describes how the **Muso.AI knowledge base repo** (this repo) is configured today, and what a DevOps engineer should do before changing any of it.

## What this repo is (and isn’t)

- **Primary purpose:** maintain the deployed knowledge surface under `skills/` and the tooling that curates it.
- **Not a product service:** this repo does **not** run the production Slack bot.
- **Production Slack integration:** handled by the **Openclaw Slack integration** (configured outside this repo).

## Live vs repo-only content

### Live (production-synced)

- `skills/` is the **deployed surface**.
- Operational contract: `skills/` is synced to the Openclaw host at `~/clawd/skills/`.

### Repo-only (provenance / internal artifacts)

- `kt-recordings/` — raw KT meeting artifacts (transcripts, summaries, metadata).
- `sources/`, `notion_sources/` — Notion exports/archives.
- `_reports/` — generated outputs (e.g., KT gap reports).

## Runtime components in this repo

### 1) Knowledge curation tooling (Python)

The canonical flow is:

1. Keep raw artifacts in `kt-recordings/<meeting_id>/`.
2. Run `scripts/curate_kt_to_skills.py` to produce:
   - Deployed curated note: `skills/muso-clio/references/kt/<meeting_id>.md`
   - Repo-only gap report: `_reports/kt-gaps/<meeting_id>.md` (+ `.json`)
3. Promote stable facts into the canonical docs under `skills/muso-clio/references/` (don’t “fix” provenance files).

## Configuration knobs (local)

Use `.env.example` as the reference for local env vars used by scripts. Key vars:

- `KT_RECORDINGS_DIR` (defaults to `./kt-recordings`)
- `LOG_LEVEL`, `NODE_ENV` (local behavior)

### `.env` / environment variables (what’s actually required)

Important: Openclaw itself is configured via `$OPENCLAW_HOME/openclaw.json` (default `$HOME/.openclaw`; not this repo’s `.env`). This repo’s env vars are only needed if you run the optional local services/tooling from this repo.

**If you need Notion access:**

- Notion integration is expected to be handled by an external Notion MCP server or connector configured alongside Openclaw (outside this repo).
- Treat Notion credentials as production secrets and inject them at runtime (do not store them in git, and avoid repo-local `.env` in production).

**If you only deploy the knowledge (`skills/`) into Openclaw:**

- No `.env` from this repo is required.
  - You still need Openclaw runtime config + secrets (Slack tokens, etc.) managed outside git.

**Production guidance (security-first):**

- Do not use a repo-local `.env` file in production.
- Inject environment variables at runtime from a secrets manager (AWS Secrets Manager / SSM).
- If using EC2 + systemd, prefer a root-owned env file outside the repo (permissions `0600`) referenced by the service unit, e.g.:
  - `/etc/openclaw/openclaw.env` (not committed)
  - `EnvironmentFile=/etc/openclaw/openclaw.env`
- If using containers (ECS/EKS), inject env vars from secrets (task definition secrets / K8s Secret) and avoid baking secrets into images.

## Quality gates / invariants

The main repository “guardrail” is:

- `npm run audit:invariants`

This validates that certain “source-of-truth” and “key resource URL” tables stay consistent across multiple deployed docs (especially the data-model references and dependent skill docs).

## Deployment (skills → Openclaw host)

In the current dev/test setup (Mac mini), this repo assumes a one-way sync of `skills/` to the Openclaw gateway machine, commonly via:

- `rsync -avz --delete skills/ <user>@<host>:~/clawd/skills/`

Notes:
- `--delete` is dangerous if you rename/move files without updating links and indexes.
- Openclaw service restart/reload is handled on the gateway host (outside this repo).
- In practice today this is often wrapped in a local shell alias (e.g. `clio-push`) that runs the rsync and any restart steps.

## Openclaw configuration (outside this repo)

The Openclaw Gateway (and Slack channel integration) is configured on the gateway host, not here. Official docs:

- `https://docs.openclaw.ai/start/getting-started`
- `https://docs.openclaw.ai/platforms/linux`
- `https://docs.openclaw.ai/help/faq`

Naming note: you may see older docs referring to **Clawdbot** or **Moltbot** — these are prior names for what is now Openclaw.

Production note: we are targeting **AWS**. Any third-party installation guides should be treated as non-authoritative and used only for general operational concepts.

Key points that matter for this repo:

- Openclaw configuration lives in `$OPENCLAW_HOME/openclaw.json` (default `$HOME/.openclaw`).
- Each agent has a `workspace` directory (configured in `openclaw.json`).
- Skills are loaded from:
  1. bundled skills
  2. managed/local skills: `$OPENCLAW_HOME/skills`
  3. workspace skills: `<workspace>/skills` (highest precedence)
- Confirm the real workspace path via `openclaw gateway status` or in `openclaw.json`.
- If you don’t (or can’t) use `<workspace>/skills`, Openclaw can also load additional skill folders via `skills.load.extraDirs` (lowest precedence).

Operational verification commands (run on the gateway host):

- `openclaw gateway status`
- `openclaw skills list --eligible`
- `openclaw status`
- `openclaw health`

## MCP Server Setup

MCP (Model Context Protocol) servers provide tools to Clio (ClickUp, Notion, etc.). These are configured via `mcporter`.

### Architecture

```
~/.env.mcp (secrets, NOT in git)
    ↓
scripts/setup-mcp.sh (reads secrets)
    ↓
~/clawd/config/mcporter.json (generated, contains secrets)
    ↓
mcporter (generates TypeScript CLI)
    ↓
Openclaw loads MCP tools
```

### Setup on a New Machine

1. **Install mcporter** (if not already installed):
   ```bash
   npm install -g mcporter
   ```

2. **Create secrets file** at `~/.env.mcp`:
   ```bash
   # Copy from example
   cp scripts/env.mcp.example ~/.env.mcp
   # Edit with your API keys
   nano ~/.env.mcp
   ```

3. **Run setup script**:
   ```bash
   ./scripts/setup-mcp.sh
   ```

4. **Restart Openclaw gateway** to load new tools:
   ```bash
   launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway
   ```

### Secrets Management

| Secret | Source | Used By |
|--------|--------|---------|
| `CLICKUP_API_KEY` | https://app.clickup.com/settings/apps | ClickUp MCP |
| `NOTION_API_KEY` | https://www.notion.so/my-integrations | Notion MCP |

**Important:**
- `~/.env.mcp` is NOT in git (in `.gitignore`)
- `mcporter.json` is NOT in git (contains secrets)
- Only `env.mcp.example` is committed (template without secrets)

### Adding New MCP Servers

1. Add the server config to `scripts/setup-mcp.sh`
2. Add the secret variable to `scripts/env.mcp.example`
3. Re-run `./scripts/setup-mcp.sh`

### Verifying MCP Tools

After setup, check if tools are available:
```bash
# In Slack, ask Clio:
@Clio what ClickUp tools do you have?

# Or check mcporter output:
cat ~/clawd/config/mcporter.json
```

## Making this production-friendly (Linux + Docker/Kubernetes)

Today’s setup is a dev/test Mac mini. A production rollout on Linux (often Docker/Kubernetes) should treat this repo’s `skills/` as a **deployable artifact** and avoid “ssh + rsync” as the primary mechanism.

Recommended production posture:

### Linux installation baseline (official)

If the production environment is a Linux host (VM/bare metal), the official docs describe an installation path that:

- Requires Node.js `>= 22`
- Installs Openclaw via npm (`npm i -g openclaw@latest`)
- Uses `openclaw onboard` to set up config and get the gateway running
- Can install a daemon via `openclaw onboard --install-daemon` (systemd user service by default)

Operationally, assume the Openclaw UI binds to localhost and use port-forwarding for access (e.g., SSH or AWS SSM port-forward) instead of exposing it publicly.

### Security posture (AWS)

This repo does not contain the Openclaw runtime config, tokens, or channel integration secrets. For AWS production, treat Openclaw like any other internet-adjacent gateway:

**Secrets management (AWS)**

- Store secrets in **AWS Secrets Manager** (or SSM Parameter Store) and inject them at runtime; do not keep secrets in this repo and do not use a repo-local `.env` in production.
- Prefer splitting IAM:
  - **Gateway runtime role**: can read only the specific secret ARNs required to start Openclaw and any sidecar services.
  - **Agent tools role** (AWS CLI inside the agent): read-only for the AWS resources you want it to inspect, but **no access to secrets**.

Concrete patterns:

- **ECS**: map Secrets Manager ARNs into container env vars via task definition `secrets`.
- **EKS**: use External Secrets Operator (or similar) to mirror Secrets Manager → Kubernetes Secret → env vars.
- **EC2 + systemd**: fetch secrets into a tmpfs envfile at boot/start (e.g. `/run/openclaw/gateway.env`, `0600`) and reference it with `EnvironmentFile=`; keep the long-lived secret source in Secrets Manager/SSM.

**Host / container hardening**

- Run as a non-root user; give it only the filesystem paths it needs (`<workspace>`, `~/.openclaw`).
- Keep the Openclaw UI bound to localhost; access via SSM/SSH port-forward for admin use.
- Put the gateway behind strict network controls (Security Groups) and avoid inbound exposure except what’s required for the channel integration.
- Ensure outbound egress is intentional (default-deny where practical; allow only required destinations).

**Secrets and credentials**

- Store channel tokens/credentials in a secrets system (AWS Secrets Manager / SSM Parameter Store), not on disk in git.
- Rotate secrets and document the rotation procedure as part of the runbook.
- Treat any “agent workspace” content as potentially sensitive: don’t mount it from shared/untrusted volumes.

**Observability and auditability**

- Centralize logs (CloudWatch Logs) and retain them long enough for incident response.
- Prefer structured health checks for automation (`openclaw health --json` if available) and alert on failures/restarts.

**Operational guardrails (agent behavior)**

Community guidance (non-authoritative, but good defaults) is to be explicit about what the agent is allowed to do:

- Require “draft-only” behavior for anything that could send messages externally (“draft the message for review” vs “send”).
- Require explicit approval for destructive operations (“before deleting any file, ask for approval”).
- Define the agent’s role to avoid impersonation (“act as an assistant, do not act as me in communications”).
- Break complex tasks into smaller steps and review after each step.
- Do not use public web-based diagram editors/renderers for Muso internal diagrams (post ASCII in-message; no rendering).

### Deploy the knowledge as an artifact

Pick one:

- **Bake an image** that contains `skills/` at `<workspace>/skills` (simple, immutable, easy rollback).
- **Mount a volume** containing `skills/` at `<workspace>/skills` (fast to update; needs careful rollout).
- **Git sync** into `<workspace>/skills` (init container or sidecar) pinned to a commit SHA/tag.

### Persist the right state

Openclaw keeps important state on disk (config, credentials, sessions). In containers you typically need persistent storage for:

- `$OPENCLAW_HOME/` (the gateway's home directory, default `$HOME/.openclaw`)

Decide explicitly what is:

- **Ephemeral** (safe to lose on restart)
- **Persistent** (must survive restarts/rollouts)
- **Secret** (must be injected via K8s Secret / Vault / SSM, not stored in git)

### Be explicit about “single gateway” vs HA

Channel integrations that rely on durable sessions/credentials often don’t behave well with active/active replicas.

- Default assumption: **1 gateway instance per channel/account**.
- If HA is required, design it intentionally (profiles/ports, separate credential stores, clear failover mechanics).

### Health checks and observability

- Use CLI-based checks (`openclaw gateway status`, `openclaw status`, `openclaw health --json`) as part of runbooks and automation.
- Ensure gateway logs are captured in production (container logs + any file logs under `/tmp/openclaw/`).

### Separate “Openclaw runtime” from “Muso content”

Keep the roles distinct:

- Openclaw runtime config and channel credentials live outside this repo.
- This repo should remain the single source of truth for the knowledge content under `skills/`.

## What a DevOps engineer should do before changing configuration

This section is intentionally procedural; it’s the “before touching anything” checklist.

### 1) Confirm the scope of “configuration”

Clarify which layer is being changed:

- **Knowledge content:** markdown under `skills/` (safe, deploy via rsync).
- **Tooling:** `scripts/` (Python) or `scripts/audit-invariants.ts` (TypeScript).
- **Runtime services:** Openclaw runtime (and any external MCP services it uses, like a Notion MCP server) plus the host’s process manager/systemd wiring.
- **Openclaw integration:** configuration lives outside this repo; changes require host access and coordination.

### 2) Inventory the current live state

Before changes, capture:

- The exact git revision being deployed (commit SHA).
- The exact deployed `skills/` tree on the Openclaw host (`~/clawd/skills/`).
- How Openclaw is started/managed (systemd unit, docker compose, etc.) and where logs live.
- The Openclaw config file in use (`$OPENCLAW_HOME/openclaw.json`) and how the gateway token/auth is configured.
- Whether Notion MCP is enabled in production, and if so where it runs and how it’s authenticated.

### 3) Risk review + rollback plan (written)

Write down:

- Primary failure modes (broken links in `skills/`, missing files due to `--delete`, invalid assumptions in curated docs).
- Rollback method:
  - re-sync the previous known-good `skills/` from a tagged commit, or
  - restore a tarball/snapshot of `~/clawd/skills/`.

### 4) Add/verify automation (recommended)

If this is being operationalized:

- Add a CI job that runs `npm run audit:invariants` on every change affecting `skills/`.
- Gate any “deploy” job on a clean invariants audit.
- Prefer “preview” diffs: show file adds/removals before executing rsync with `--delete`.

### 5) Pre-deploy validation (every time)

Run locally:

- `npm run audit:invariants`

And sanity check:

- `skills/muso-clio/references/INDEX.md` still links into the moved/added docs appropriately.
- Any renamed/moved file has its inbound links updated.

### 6) Execute change in a controlled way

- Deploy during a low-traffic window (if the Slack integration is business-critical).
- Sync `skills/` to the host.
- Restart/reload the Openclaw integration if needed.
- Validate on Slack with a small set of known queries (smoke tests) and confirm citations/links resolve.

### 7) Post-change monitoring

- Watch logs for spikes in errors/timeouts.
- Collect user feedback (“wrong/outdated”, “needs doc”) and feed it back into curation.
