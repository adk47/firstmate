# HYDRA Onboarding Guide

> **Version**: 1.0 (created 2026-03-22; revised periodically since)
>
> This guide covers everything you need to know to work with HYDRA, whether you are an
> agent owner, an administrator, or a developer contributing to the platform.

---

## Table of Contents

1. [For Agent Owners](#for-agent-owners) (Nick, Liza, Jan, Serhii, Mariia)
2. [For Aaron (Admin)](#for-aaron-admin)
3. [For Developers (CTO Team)](#for-developers-cto-team)

---

## For Agent Owners

You have been assigned an AI agent that lives in Slack. Here is what you need to know.

### Your Agent

| Owner   | Agent        | Slack Name    | What It Does                                  |
|---------|--------------|---------------|-----------------------------------------------|
| Aaron   | ceo          | @CEO          | Strategy, business decisions, planning        |
| Nick    | cmo          | @CMO          | Marketing, growth, comms, campaigns           |
| Nick+Serhii | cto      | @CTO          | Technical leadership, architecture decisions  |
| Nick+Serhii | qa       | @QA           | Testing, quality assurance, bug triage        |
| Liza    | finance      | @Finance      | Financial analysis, budgets, forecasts        |
| Jan     | operations   | @Operations   | Operational workflows, logistics, processes   |
| Nick    | scout        | @Scout        | Web research, competitive/market intel, company discovery |
| Aaron   | coordinator  | @Buddy        | General help, triage, coordination            |
| Nick / Serhii | devops   | @DevOps       | Infrastructure, CI/CD, deployments            |

### How to Interact with Your Agent

**Direct Message (DM):**
Open a DM with your agent's Slack app (e.g., @CEO) and type your question or request.
This is a private conversation between you and the agent.

**Channel Mention:**
In any channel where the agent is a member, mention it by name (e.g., `@CEO can you
review this proposal?`). The agent will respond in the channel thread.

**What works well:**
- Be specific about what you need
- Provide context (paste documents, links, data)
- Ask follow-up questions in the same thread
- The agent remembers context within a conversation thread

**What does not work:**
- The agent cannot see messages in channels it has not been added to
- The agent cannot access your screen, files on your computer, or external tools
  unless they have been explicitly configured
- The agent does not have access to email, calendars, or other SaaS tools
  (only what is listed in its TOOLS.md)

### How to Customize Your Agent

Your agent's behavior is controlled by files in the `hydra` repo under
`workspaces/{agent-id}/`. Here is what you can change:

| File       | What It Controls           | Can You Edit?                         |
|------------|---------------------------|---------------------------------------|
| SOUL.md    | Identity, rules, deny list | No -- requires Aaron's approval       |
| AGENTS.md  | Knowledge of other agents  | No -- requires Aaron's approval       |
| TOOLS.md   | Tool configurations        | No -- requires Aaron's approval       |
| USER.md    | Your info, preferences     | Yes -- submit a PR, self-merge OK     |
| MEMORY.md  | Learned context            | Yes -- submit a PR, self-merge OK     |

**To make a change:**

1. Go to `https://github.com/Muso-AI/hydra`
2. Navigate to `workspaces/{your-agent-id}/`
3. Edit the file (USER.md or MEMORY.md)
4. Create a pull request
5. For USER.md and MEMORY.md: you can merge it yourself
6. For SOUL.md, AGENTS.md, TOOLS.md: Aaron must review and approve

**Common customizations:**
- Update USER.md with your preferred communication style
- Add project context to MEMORY.md so the agent has background info
- Request new tool capabilities by opening an issue in the hydra repo

### What Your Agent Cannot Do

Each agent has a tool deny list defined in its SOUL.md. Common restrictions include:

- Cannot execute arbitrary shell commands on production servers
- Cannot access other agents' workspaces
- Cannot modify its own SOUL.md or security rules
- Cannot make purchases or sign contracts
- Cannot access credentials or secrets directly

The exact deny list varies per agent. Check your agent's SOUL.md for specifics.

### How to Report Issues

If your agent is not responding, giving incorrect answers, or behaving unexpectedly:

1. **Quick check**: Is the agent in the channel? (Check channel members)
2. **Try DM**: If it does not respond in a channel, try a direct message
3. **Report**: Post in `#hydra-support` (if available) or DM @Aaron
4. **Include**: What you asked, what happened (or did not happen), the channel name

---

## For Aaron (Admin)

### Accessing Node 8

```bash
ssh root@40.160.32.80
# or via vRack from another OVH node:
ssh root@10.0.0.8
```

SSH key: `~/.ssh/ovh_muso` (same key used for all OVH nodes).

### Restarting the Gateway

```bash
# Restart the OpenClaw gateway (inside NemoClaw sandbox)
ssh root@40.160.32.80 "docker restart hydra-sandbox"

# Verify it came back up
ssh root@40.160.32.80 "docker logs hydra-sandbox --tail 20"

# Check all agents are connected
ssh root@40.160.32.80 "docker exec hydra-sandbox openclaw agents list"
```

After a restart, all 9 agents will reconnect to Slack via Socket Mode. This typically
takes 10-15 seconds.

### Adding/Removing Slack Channels

Agents see messages only in channels where their Slack app has been added.

**To add an agent to a channel:**
1. Go to the Slack channel
2. Click the channel name to open settings
3. Click "Integrations" then "Add apps"
4. Search for the agent's Slack app name and add it

**To remove an agent from a channel:**
1. Go to the channel settings
2. Click "Integrations" then "Apps"
3. Remove the agent's app

No server-side changes are needed. Channel membership is entirely managed in Slack.

### Rotating Tokens

**Slack tokens** (bot token + app-level token per agent):
1. Go to `api.slack.com/apps` and select the agent's app
2. Regenerate the token
3. Update the secret in Vault: `vault kv put secret/hydra/{agent-id}/slack bot_token=xoxb-... app_token=xapp-...`
4. ESO will sync to the K8s secret automatically
5. Restart the gateway: `docker restart hydra-sandbox`

**OpenRouter API key** (`OPENROUTER_API_KEY` — sole inference path):
1. Issue a new key at https://openrouter.ai/keys
2. Update Vault: `vault kv put secret/hydra/openrouter api_key=sk-or-...`
3. ESO syncs to `/opt/hydra/secrets/llm-provider-keys.json` automatically
4. Restart: `docker restart hydra-sandbox`

### Reading Audit Logs

```bash
# Clone or pull the audit repo
git clone git@github.com:Muso-AI/hydra-audit.git
# or
cd hydra-audit && git pull

# Logs are organized by date and agent
ls logs/2026-03-22/
# coordinator.jsonl  ceo.jsonl  cmo.jsonl  ...

# View recent interactions for a specific agent
tail -50 logs/2026-03-22/ceo.jsonl | jq .
```

On Node 8, the raw audit buffer is at `/opt/hydra/audit/`. The hourly CronJob commits
and pushes this to the hydra-audit repo.

### Adding a New Agent

1. **Create the Slack app** at `api.slack.com/apps`:
   - Enable Socket Mode
   - Add bot scopes: `chat:write`, `app_mentions:read`, `channels:history`, `im:history`
   - Install to workspace
   - Note the bot token and app-level token

2. **Create the workspace** in the hydra repo:
   ```
   workspaces/{new-agent-id}/
   |-- SOUL.md
   |-- AGENTS.md
   |-- TOOLS.md
   |-- USER.md
   |-- MEMORY.md
   +-- skills/
   ```

3. **Add agent config** to `openclaw.json`:
   - Agent ID, model assignment, workspace path, Slack app credentials reference

4. **Store secrets in Vault**:
   ```bash
   vault kv put secret/hydra/{new-agent-id}/slack \
     bot_token=xoxb-... \
     app_token=xapp-...
   ```

5. **Update AGENTS.md** in all existing workspaces so they know about the new agent

6. **Deploy**: Restart the gateway (`docker restart hydra-sandbox`)

7. **Add the new agent's Slack app** to the appropriate channels

### Monitoring and Alerts

| What                   | How to Check                                          |
|------------------------|-------------------------------------------------------|
| Gateway health         | `docker ps` -- check hydra-sandbox is running         |
| Agent connectivity     | `docker exec hydra-sandbox openclaw agents list`      |
| OpenRouter reachable   | `docker exec hydra-sandbox curl -sS -o /dev/null -w '%{http_code}\n' https://openrouter.ai/api/v1/models` |
| Audit pipeline         | Check hydra-audit repo for hourly commits             |
| Node 8 resources       | `htop`, `df -h`, `docker stats`                       |
| K3s node status        | `kubectl get nodes` (from any control plane node)     |

Alerts are configured via Prometheus (on the existing monitoring stack) and fire to
the `#ops-alerts` Slack channel.

---

## For Developers (CTO Team)

### Repository Structure

```
Muso-AI/hydra/
|-- .github/
|   +-- workflows/          # CI/CD pipelines
|-- CODEOWNERS               # PR approval rules
|-- docs/
|   |-- ARCHITECTURE.md      # This architecture document
|   |-- ONBOARDING.md        # This onboarding guide
|   |-- RUNBOOK.md           # Operational runbook
|   +-- REPO-MANAGEMENT.md   # Repo management policies
|-- extraction/              # Data extraction utilities
|-- openclaw.json            # OpenClaw gateway configuration (agent definitions)
|-- policies/                # Security and governance policies
|-- scripts/
|   |-- deploy.sh            # Deployment scripts
|   |-- health-check.sh      # Health check utilities
|   +-- ...
|-- secrets/                 # Secret references (NOT actual secrets)
|-- ui/                      # HYDRA management UI components
+-- workspaces/
    |-- coordinator/         # Buddy agent workspace
    |-- ceo/                 # CEO agent workspace
    |-- cmo/                 # CMO agent workspace
    |-- cto/                 # CTO agent workspace
    |-- qa/                  # QA agent workspace
    |-- finance/             # Finance agent workspace
    |-- operations/          # Operations agent workspace
    |-- devops/              # DevOps agent workspace
    +-- scout/               # Scout (research) agent workspace
```

### How to Contribute

1. **Fork or branch**: Create a feature branch from `main`
2. **Make changes**: Edit the relevant files
3. **Test locally**: If modifying agent behavior, test with a staging agent first
4. **Submit PR**: Open a pull request against `main`
5. **Review**: CODEOWNERS determines who must approve
   - SOUL.md, AGENTS.md, TOOLS.md, policies/ --> Aaron must approve
   - USER.md, MEMORY.md --> Agent owner can self-merge
   - openclaw.json, scripts/, docs/ --> Aaron or CTO must approve
6. **Merge**: Squash merge is preferred

### CODEOWNERS Rules

The `CODEOWNERS` file enforces review requirements:

- `workspaces/*/SOUL.md` --> @adk47
- `workspaces/*/AGENTS.md` --> @adk47
- `workspaces/*/TOOLS.md` --> @adk47
- `openclaw.json` --> @adk47
- `policies/` --> @adk47
- `scripts/` --> @adk47
- Everything else --> standard review process

### CI/CD Pipeline

The pipeline runs on every PR and on merge to `main`:

1. **Lint**: Validates JSON configs, checks Markdown formatting
2. **Security scan**: Ensures no secrets are committed, validates SOUL.md integrity
3. **Config validation**: Validates openclaw.json schema
4. **Deploy** (on merge to main): SSH to Node 8, pull latest config, restart gateway

Deployment is automated but can be triggered manually:

```bash
# From Node 8
cd /opt/hydra
git pull origin main
docker restart hydra-sandbox
```

### How to Test Changes

**Agent behavior changes (SOUL.md, TOOLS.md):**
- Test in a staging channel before deploying to production
- Use a test Slack workspace if available
- Review the audit logs after testing to verify behavior

**Configuration changes (openclaw.json):**
- Validate JSON syntax: `jq . openclaw.json`
- Check the schema matches expected format
- Deploy to staging first if making structural changes

**Script changes:**
- Test on a non-production node or in a Docker container
- Never test deployment scripts directly on Node 8 production

### Key Files to Understand

| File              | Purpose                                                     |
|-------------------|-------------------------------------------------------------|
| `openclaw.json`   | Master config -- defines all agents, models, workspace paths |
| `CODEOWNERS`      | Who must approve PRs for which files                        |
| `workspaces/*/SOUL.md` | The most important file per agent -- its identity and rules |
