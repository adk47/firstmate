# Workspace File Ownership — Deploy vs Agent State

## Overview

HYDRA agent workspaces contain two categories of files:

1. **Repo-authoritative (config)** — deployed from GitHub, overwritten on every CI/CD deploy
2. **Agent-owned (state)** — created/modified by agents at runtime, preserved across deploys

`deploy.sh` is the single source of truth for rsync excludes (as of the 2026-04-08 CD consolidation). The audit repo (`Muso-AI/hydra-audit`) captures all files every 10 minutes as backup.

## File Ownership Matrix

### Repo-Authoritative — Deployed from GitHub

| File | Purpose | Who Edits | How to Change |
|------|---------|-----------|---------------|
| `SOUL.md` | Agent personality, rules, security boundaries | Humans via PR | PR → merge → deploy |
| `AGENTS.md` | Inter-agent awareness and routing | Humans via PR | PR → merge → deploy |
| `TOOLS.md` | Tool configuration (API hosts, credentials refs) | Humans via PR | PR → merge → deploy |
| `USER.md` | Owner preferences and access levels | Humans via PR | PR → merge → deploy |
| `BOOTSTRAP.md` | One-time first-run ritual | Humans via PR | PR → merge → deploy |
| `skills/` | All skill files (SKILL.md, scripts, references) | Humans via PR | PR → merge → deploy |

### Agent-Owned — Preserved Across Deploys

| File/Dir | Purpose | Who Writes | Backup Location |
|----------|---------|-----------|-----------------|
| `MEMORY.md` | Long-term durable facts, decisions, context | Agent (runtime) | hydra-audit repo (10 min) |
| `HEARTBEAT.md` | Automation configs, cron task definitions | Agent + humans via Slack | hydra-audit repo (10 min) |
| `IDENTITY.md` | Agent identity metadata (name, theme) | Agent (bootstrap) | hydra-audit repo (10 min) |
| `memory/` | Daily working notes (`memory/YYYY-MM-DD.md`) | Agent (runtime) | hydra-audit repo (10 min) |
| `api-logs/` | API call audit trail | Agent (runtime) | hydra-audit repo (10 min) |
| `backups/` | Agent-created backups | Agent (runtime) | Not backed up externally |
| `reports/` | Generated reports (CSVs, PDFs) | Agent (runtime) | Not backed up externally |
| `.openclaw/` | Workspace state (sessions, workspace-state.json) | OpenClaw runtime | Not backed up externally |

## Why HEARTBEAT.md and IDENTITY.md are Agent-Owned

Standard OpenClaw documentation classifies these as config files loaded at boot. However, in HYDRA's multi-agent setup:

- **HEARTBEAT.md** — Agents actively modify this via Slack conversations. CMO's HEARTBEAT.md contains 5.3KB of B2B automation configs that Fede updates through the CMO agent. Overwriting it on deploy would destroy those configurations.
- **IDENTITY.md** — Generated during the bootstrap ritual and updated by agents during conversations. Contains agent-specific metadata that shouldn't be reset.

If you need to push a HEARTBEAT.md or IDENTITY.md change from the repo, use a targeted rsync without the exclude flag, or SSH and copy the specific file.

**Single source of truth (2026-04-08):** Both `deploy.sh` and `deploy.yml` used to have their own exclude lists for these files. After the CD consolidation, only `deploy.sh`'s `RSYNC_EXCLUDES` list matters — `deploy.yml` no longer does its own rsync.

## Rsync Exclude Configuration

As of the 2026-04-08 CD consolidation, **`scripts/deploy.sh` is the single source of truth** for rsync exclude lists. The previous `deploy.yml` workspace sync step has been deleted — all file sync now flows through `deploy.sh` Step 4b with a unified exclude list.

### deploy.sh RSYNC_EXCLUDES

```bash
RSYNC_EXCLUDES=(
  # Repo hygiene
  --exclude='.git'
  --exclude='hydra docs/'
  --exclude='secrets/'
  --exclude='.deployed-sha'

  # Workspace runtime data (real, accumulating data)
  --exclude='workspaces/*/memory/'
  --exclude='workspaces/*/api-logs/'
  --exclude='workspaces/*/MEMORY.md'
  --exclude='workspaces/*/backups/'
  --exclude='workspaces/*/reports/'
  --exclude='workspaces/*/.openclaw/'
  --exclude='workspaces/*/IDENTITY.md'
  --exclude='workspaces/*/HEARTBEAT.md'

  # Audit logs and backups (per-workspace memory snapshots)
  --exclude='audit/'
  --exclude='audit-local-backup/'

  # Dead CD shadow mirror (being removed post-2026-04-08 consolidation)
  --exclude='config/'

  # Plugin install artifacts (npm install in-place on server)
  --exclude='plugins/*/node_modules/'
  --exclude='plugins/*/package-lock.json'
)
```

The list is enforced by `.githooks/pre-commit` Check 2, which verifies that every entry in `required_excludes` is present in the script AND that every `rsync` call in `deploy.sh` references `"${RSYNC_EXCLUDES[@]}"`. If you add a new exclude, also add it to `required_excludes` in the pre-commit hook.

### deploy.yml

`deploy.yml` no longer has its own rsync step. It is now a thin wrapper that:
1. Validates `SLACK_WEBHOOK` (fail-fast)
2. Detects the target profiles (`--target main,edge,dev,all`)
3. Calls `./scripts/deploy.sh --target $TARGET`
4. Posts Slack notifications with GitHub context
5. Triggers `rollback.sh` on failure

All rsync and exclude logic lives in `deploy.sh`.

## Recovery

If agent-owned files are accidentally overwritten:

1. **From hydra-audit repo**: `git clone Muso-AI/hydra-audit`, find the latest snapshot in `workspaces/<agent>/`
2. **From Vault**: API keys and secrets at `secret/hydra/*`
3. **From node-8 backup**: Check `/opt/hydra/audit-local-backup/` for pre-migration snapshots

## References

- [OpenClaw Workspace Files Explained](https://capodieci.medium.com/ai-agents-003-openclaw-workspace-files-explained-soul-md-agents-md-heartbeat-md-and-more-5bdfbee4827a)
- [OpenClaw Memory Documentation](https://docs.openclaw.ai/concepts/memory)
- [OpenClaw Heartbeat Documentation](https://docs.openclaw.ai/gateway/heartbeat)
- PR #43 — deploy.sh excludes (Nick)
- PR #65 — drift check, pre-flight, smoke-test gate infrastructure
- PR #67 — deploy.yml exclude alignment (Aaron, superseded by the CD consolidation PR)
- `docs/superpowers/specs/2026-04-08-cd-pipeline-comprehensive-fix-design.md` — the spec for the single-pipeline architecture
