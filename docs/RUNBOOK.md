# HYDRA Operational Runbook

> **Version**: 1.0 | **Date**: 2026-03-22
>
> Step-by-step procedures for operating, troubleshooting, and recovering the HYDRA system.
> Intended audience: Aaron and anyone with SSH access to Node 8.

---

## Table of Contents

1. [Common Operations](#common-operations)
2. [Deploy](#deploy)
3. [Troubleshooting](#troubleshooting)
4. [Emergency Procedures](#emergency-procedures)

---

## Common Operations

### Check System Status

```bash
# Check all Docker containers are running
ssh root@40.160.32.80 "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# Expected output:
# NAMES            STATUS          PORTS
# hydra-sandbox    Up X hours      127.0.0.1:18789->18789/tcp
```

### Check Agent Status

```bash
# List all agents and their connection state
ssh root@40.160.32.80 "docker exec hydra-sandbox openclaw agents list"

# Expected: all 9 agents showing "connected" status
```

### Restart the Gateway

```bash
# Restart (agents will reconnect to Slack in ~10-15 seconds)
ssh root@40.160.32.80 "docker restart hydra-sandbox"

# Verify
ssh root@40.160.32.80 "docker logs hydra-sandbox --tail 30"
```

### View Gateway Logs

```bash
# Last 50 lines
ssh root@40.160.32.80 "docker logs hydra-sandbox --tail 50"

# Follow logs in real time (Ctrl+C to stop)
ssh root@40.160.32.80 "docker logs hydra-sandbox -f"

# Logs from a specific time window
ssh root@40.160.32.80 "docker logs hydra-sandbox --since '2026-03-22T10:00:00' --until '2026-03-22T11:00:00'"
```

### Check Slack Connections

```bash
# Look for Socket Mode connection events
ssh root@40.160.32.80 "docker logs hydra-sandbox 2>&1 | grep -i 'socket mode'"

# Each agent should show "socket mode connected" in the logs
```

### Check Node 8 Resource Usage

```bash
ssh root@40.160.32.80 "docker stats --no-stream"
ssh root@40.160.32.80 "free -h"
ssh root@40.160.32.80 "df -h"
```

### Check K3s Node Status

```bash
# From any control-plane node (node-1, node-2, or node-3)
ssh root@10.0.0.1 "kubectl get node ovh-node-8"

# Expected: Ready status with hydra taint
```

### View Audit Logs

```bash
# On Node 8, raw audit buffer
ssh root@40.160.32.80 "ls -la /opt/hydra/audit/"

# On GitHub (hydra-audit repo)
# Commits happen hourly; check the latest
ssh root@40.160.32.80 "cd /opt/hydra/audit && git log --oneline -5"
```

### Pull Latest Configuration

```bash
ssh root@40.160.32.80 "cd /opt/hydra && git pull origin main"

# Then restart to pick up changes
ssh root@40.160.32.80 "docker restart hydra-sandbox"
```

---

## Deploy

### Overview

Hydra deploys are triggered by `git push` to `main`. A self-hosted GitHub Actions runner (which runs ON node-8) executes `.github/workflows/deploy.yml`, a thin wrapper around `scripts/deploy.sh`. The script runs end-to-end on node-8 and handles everything: rsync, skills, plugins, k8s, gateway restart, smoke test, and baseline update.

### Flow

1. `push` to `main` → GH Actions triggers `deploy.yml`
2. `deploy.yml` validates `SLACK_WEBHOOK` is set (fail-fast)
3. `deploy.yml` checks out the repo
4. `deploy.yml` detects target profiles based on `git diff HEAD~1 HEAD` (main, edge, dev, or combinations)
5. `deploy.yml` calls `./scripts/deploy.sh --target $TARGET`
6. `deploy.sh` runs through its steps:
   - **Step 0**: drift check (vs `.deployed-sha` baseline)
   - **Step 1**: validate openclaw JSON configs + cron-jobs.json
   - **Step 2**: validate SOUL.md presence per profile
   - **Step 3**: validate tool-deny-lists.yaml (only-grow check)
   - **Step 4a**: pre-flight `--delete` guard (rsync dry-run)
   - **Step 4b**: rsync repo → `/opt/hydra/` (with `RSYNC_EXCLUDES`)
   - **Step 4c**: sync global skills → `/root/.openclaw-<profile>/skills/` (per profile: main, edge, dev)
   - **Step 4d**: install plugins (npm install + copy to extension dirs)
   - **Step 5a**: POSTSYNC setup (AWS creds, GOG keyring, Gmail patches, cron sync)
   - **Step 5b**: apply k8s manifests (skipped silently if `k8s/prod/hydra/` missing)
   - **Step 6**: `systemctl restart` targeted gateways
   - **WARMUP**: poll agents bind status until ready (30s timeout)
   - **Step 7**: smoke test — if passes, writes `.deployed-sha` baseline
   - **Step 8**: AWS data-plane verify (non-fatal)
   - **Step 9**: post status
7. `deploy.yml` posts Slack notification (success or failure)
8. On failure, `deploy.yml` triggers `rollback.sh`, which detects `HYDRA_LOCAL` and runs locally on node-8

### Manual deploy

You can run a deploy manually from node-8:

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80
cd /opt/hydra
./scripts/deploy.sh --target dev   # or main, edge, all, main,edge
```

### Bypass environment variables

- `HYDRA_FORCE=1` — skip the Step 0 drift check against `.deployed-sha` AND the Step 4a pre-flight delete/skills-drift guards. **Does NOT skip the Step 7 smoke test** — that always runs and always blocks the deploy on hard-gate failures. The equivalent of `git push --force` over a colleague's edits. Briefings tell you to confirm with a human before using.
- `HYDRA_SKIP_DRIFT_CHECK=1` — skip only the Step 0 drift check. Use when SSH to baseline read is broken.
- `HYDRA_CONTINUE_ON_PLUGIN_FAIL=1` — don't fail on first plugin install error; collect all failures and report at the end.
- `HYDRA_ALLOW_ORPHAN_CRON=1` — allow cron-sync to drop live state for removed jobs.

### Verification after a deploy

Run these from your laptop (or from node-8) to verify deploy health:

```bash
# Gateways running?
ssh root@40.160.32.80 'systemctl is-active openclaw-gateway-main openclaw-gateway-edge'

# Baseline SHA updated?
ssh root@40.160.32.80 'cat /opt/hydra/.deployed-sha'
# Should match the merge commit SHA

# Agents loaded?
ssh root@40.160.32.80 'openclaw --profile main agents list --bindings | head -20'

# Cron scheduler active?
ssh root@40.160.32.80 'openclaw --profile main cron status --json | jq .'

# Watchdog still ticking?
ssh root@40.160.32.80 'tail -5 /var/log/openclaw-watchdog.log'

# Smoke test fresh run?
ssh root@40.160.32.80 'cd /opt/hydra && ./scripts/smoke-test.sh main'
```

### Troubleshooting

- **Deploy fails at Step 0 (drift check)** — the server has files the repo doesn't. See briefing in deploy log for the list. Use `scripts/sync-from-server.sh` to pull server-side edits into the repo first, commit, then retry the deploy.
- **Deploy fails at Step 4a (pre-flight)** — rsync `--delete` would remove server files not in the repo. See briefing in the deploy log for the list and recovery steps.
- **Deploy fails at Step 4d (plugin install)** — npm install failed for a specific plugin. The error message names the plugin and its stderr. Fix the `package.json` or dependencies and retry. Set `HYDRA_CONTINUE_ON_PLUGIN_FAIL=1` to see all plugin failures at once.
- **Deploy fails at Step 5b (k8s apply)** — rollback yaml is at `/tmp/hydra-rollback-deployments.yaml` on node-8. To revert: `kubectl apply -f /tmp/hydra-rollback-deployments.yaml -n hydra`
- **Deploy fails at Step 7 (smoke test)** — check the smoke test output in the deploy log. Entries prefixed `FAIL:` are hard-gate failures and block the deploy; entries prefixed `WARN:` are soft-gate warnings and are informational only. The smoke test exits 0 unless `FAILURES > 0`.
- **Slack alerts not firing** — the `HYDRA_SLACK_WEBHOOK` secret is missing or empty. The presence check in `deploy.yml` surfaces this as a `::warning::` annotation on every workflow run (non-blocking — deploys still proceed). To fix: get the `#hydra-heartbeat` webhook URL from the Slack app settings and run `gh secret set HYDRA_SLACK_WEBHOOK --repo Muso-AI/hydra`. If you want the presence check to be a hard gate instead of a warning, change `::warning::` → `::error::` and add `exit 1` in the "Check SLACK_WEBHOOK presence" step.

---

## Troubleshooting

### Agent Not Responding

**Symptoms**: User mentions or DMs an agent in Slack and gets no response.

**Diagnosis steps:**

1. **Is the gateway running?**
   ```bash
   ssh root@40.160.32.80 "docker ps | grep hydra-sandbox"
   ```
   If not running, restart it: `docker restart hydra-sandbox`

2. **Is the agent connected?**
   ```bash
   ssh root@40.160.32.80 "docker exec hydra-sandbox openclaw agents list"
   ```
   Look for the agent's status. If disconnected, check Slack tokens.

3. **Is the agent in the channel?**
   In Slack, check channel settings > Integrations > Apps. The agent's app must be
   listed as a member.

4. **Check gateway logs for errors:**
   ```bash
   ssh root@40.160.32.80 "docker logs hydra-sandbox --tail 100 2>&1 | grep -i error"
   ```

5. **Is OpenRouter reachable?**
   ```bash
   ssh root@40.160.32.80 "docker exec hydra-sandbox curl -sS -o /dev/null -w '%{http_code}\n' https://openrouter.ai/api/v1/models"
   ```
   `200` = healthy. Anything else (timeout, 401, 5xx) means inference will fail for every agent.

**Resolution**: Usually one of: restart gateway, add agent to channel, or wait out an OpenRouter / upstream provider incident.

---

### OpenRouter Outage

**Symptoms**: Agents receive messages but never respond, or respond with error messages mentioning 5xx / timeout / `upstream`.

**Diagnosis:**

```bash
ssh root@40.160.32.80 "docker exec hydra-sandbox curl -sS -o /dev/null -w '%{http_code}\n' https://openrouter.ai/api/v1/models"
ssh root@40.160.32.80 "docker logs hydra-sandbox --tail 50 2>&1 | grep -iE 'openrouter|429|529|overloaded'"
```

**Common causes and fixes:**

| Cause                              | Fix                                                              |
|------------------------------------|------------------------------------------------------------------|
| OpenRouter incident                | Watch https://status.openrouter.ai/ — wait, then retry           |
| `OPENROUTER_API_KEY` revoked / 401 | Rotate the key in `/opt/hydra/secrets/llm-provider-keys.json`, restart gateway |
| Rate limit (429)                   | Reduce concurrency or temporarily lower `maxConcurrent` per profile |
| Upstream Anthropic / OpenAI outage | OR returns 5xx; wait for upstream to recover                     |

---

### Gateway Crash / Restart Loop

**Symptoms**: hydra-sandbox container keeps restarting.

**Diagnosis:**

```bash
# Check restart count
ssh root@40.160.32.80 "docker inspect hydra-sandbox --format '{{.RestartCount}}'"

# Check recent logs (the crash reason is usually in the last few lines before restart)
ssh root@40.160.32.80 "docker logs hydra-sandbox --tail 100"
```

**Common causes:**

| Cause                    | Fix                                                    |
|--------------------------|--------------------------------------------------------|
| Bad openclaw.json        | Fix the JSON, redeploy, restart                        |
| Corrupted workspace file | Check SOUL.md files for syntax issues                  |
| Out of memory            | Check `docker stats`, increase container memory limit  |
| NemoClaw sandbox error   | Recreate the container (see below)                     |

**Recreating the sandbox container:**
```bash
ssh root@40.160.32.80
docker rm -f hydra-sandbox
# Re-run the container creation command from the deploy script
/opt/hydra/scripts/deploy.sh
```

---

### Legacy openclaw-gateway Zombie

**Symptoms:** smoke-test fails with `Legacy openclaw-gateway.service is ...
— must be masked`, OR `openclaw-gateway-main.service` keeps dying every
~20s with a SIGTERM it didn't ask for, OR `openclaw --profile main cron
status --json` reports `storePath: /root/.openclaw/cron/jobs.json` (the
pre-migration legacy path) instead of `/root/.openclaw-main/cron/jobs.json`.

**Background:** Before PR #43 split the gateway into `main`/`edge`/`dev`
profiles, there was a single `openclaw-gateway.service` (no `-main`
suffix). After migration, that legacy unit should have been removed but
in some environments it persisted as `disabled` — which does NOT stop a
running instance. A `disabled`-but-`active` legacy unit binds port 18789
without `--profile`, runs openclaw with the pre-migration data dir
(`/root/.openclaw/`), and its service-mode pid-clearing SIGTERMs the
real `openclaw-gateway-main.service` every ~20s. It also answers CLI
queries with the wrong storePath, creating silent drift between deploys
and gateway reads. One such zombie was found on node-8 on 2026-04-21
and caused a ~90-minute gateway instability window plus ~2 hours of
debugging chasing a phantom upstream bug.

**Diagnosis:**

```bash
ssh root@40.160.32.80
systemctl is-enabled openclaw-gateway.service  # should be 'masked' or 'not-found'
systemctl is-active openclaw-gateway.service   # should be 'inactive' or error
# If either is anything else — especially if is-active=active with any
# is-enabled value — you have the zombie.
```

**Full remediation** (this is what was applied on node-8 2026-04-21 and
what the smoke-test gate enforces on every deploy):

```bash
ssh root@40.160.32.80
# 1. Stop any live zombie process first. `mask` alone does NOT stop a
#    running unit — it only prevents future starts.
systemctl stop openclaw-gateway.service 2>/dev/null || true

# 2. Rename (don't delete) the legacy unit file and drop-in directory so
#    forensics are preserved. Systemd ignores anything not matching *.service.
TS=$(date +%Y%m%d-%H%M%S)
if [ -f /etc/systemd/system/openclaw-gateway.service ]; then
  mv /etc/systemd/system/openclaw-gateway.service{,.legacy-disabled-$TS}
fi
if [ -d /etc/systemd/system/openclaw-gateway.service.d ]; then
  mv /etc/systemd/system/openclaw-gateway.service.d{,.legacy-disabled-$TS}
fi

# 3. Reload systemd's view and mask the unit name so future
#    `systemctl start openclaw-gateway.service` is refused.
systemctl daemon-reload
systemctl mask openclaw-gateway.service

# 4. Verify.
systemctl is-enabled openclaw-gateway.service  # masked
systemctl is-active openclaw-gateway.service   # inactive
openclaw --profile main cron status --json | jq .storePath
# → expect "/root/.openclaw-main/cron/jobs.json"

# 5. Restart openclaw-gateway-main so it recovers cleanly.
systemctl restart openclaw-gateway-main.service
```

**Why mask alone is not enough:** `systemctl mask` points the unit at
`/dev/null` so new starts fail. It does not kill a process already
running, and the drop-in dir at `/etc/systemd/system/openclaw-gateway.service.d/`
remains — if the mask is ever lifted, the original config is still
loadable. Renaming the unit file and drop-in dir in step 2 is the
belt-and-suspenders part.

**Prevention:** `scripts/smoke-test.sh` runs a zombie guard on every
deploy that hard-fails if the legacy unit is anything other than
`masked`/`masked-runtime`/`not-found`. `scripts/deploy.sh` additionally
mirrors `cron-jobs.json` to both the profile and legacy paths so if the
zombie ever reanimates before smoke-test catches it, the drift window
is one deploy cycle rather than weeks.

---

### NemoClaw Sandbox Issues

**Symptoms**: Permission denied errors, filesystem read-only errors, or network failures
inside the sandbox.

**Diagnosis:**
```bash
# Check sandbox user
ssh root@40.160.32.80 "docker exec hydra-sandbox whoami"
# Expected: sandbox

# Check filesystem permissions
ssh root@40.160.32.80 "docker exec hydra-sandbox ls -la /opt/hydra/workspaces/coordinator/"

# Check network connectivity from inside sandbox
ssh root@40.160.32.80 "docker exec hydra-sandbox curl -sS -o /dev/null -w '%{http_code}\n' https://openrouter.ai/api/v1/models"
```

**Fix: Full sandbox recreation:**
```bash
ssh root@40.160.32.80
docker rm -f hydra-sandbox
/opt/hydra/scripts/deploy.sh
```

---

### Token Expired or Revoked

**Slack tokens:**
```bash
# Check which agent's token is failing
ssh root@40.160.32.80 "docker logs hydra-sandbox 2>&1 | grep -i 'auth\|token\|invalid'"

# Rotate the token:
# 1. Go to api.slack.com/apps, select the agent's app
# 2. Regenerate the token
# 3. Update Vault
vault kv put secret/hydra/{agent-id}/slack bot_token=xoxb-... app_token=xapp-...
# 4. ESO syncs automatically, then restart
ssh root@40.160.32.80 "docker restart hydra-sandbox"
```

**OpenRouter API key:**
If `OPENROUTER_API_KEY` is rotated or revoked, update it in
`/opt/hydra/secrets/llm-provider-keys.json` (the `hydra-secrets` file
provider) and restart the gateway:
```bash
ssh root@40.160.32.80 "docker restart hydra-sandbox"
```

---

### Node 8 Unreachable

**Symptoms**: Cannot SSH to 40.160.32.80, agents are all offline.

**Diagnosis steps:**

1. **Check from another OVH node via vRack:**
   ```bash
   ssh root@10.0.0.1 "ping -c 3 10.0.0.8"
   ```
   If vRack responds but public IP does not, it is likely a firewall or public interface issue.

2. **Check OVH console:**
   Log in to OVH US control panel and check the server status for ns-XXXXXX (Node 8).
   Look for hardware alerts or network issues.

3. **Check K3s node status:**
   ```bash
   ssh root@10.0.0.1 "kubectl get node ovh-node-8"
   ```
   If status is `NotReady`, the node may be rebooting or have a kernel issue.

4. **OVH KVM console:**
   If SSH is completely dead, use the OVH IPMI/KVM console from the control panel
   to access the server's console directly.

**Common causes:**

| Cause               | Fix                                                      |
|----------------------|----------------------------------------------------------|
| iptables locked out  | Use OVH KVM console to fix firewall rules                |
| Server rebooted      | Docker containers should auto-restart; verify with SSH   |
| NIC down             | Check OVH console, may need OVH support ticket           |
| Hardware failure     | OVH support ticket, failover to Clio (see Emergency)     |

---

### Audit Pipeline Not Committing

**Symptoms**: hydra-audit repo has no recent commits (should be hourly).

**Diagnosis:**
```bash
# Check the CronJob
ssh root@10.0.0.1 "kubectl get cronjob -n hydra"

# Check recent job runs
ssh root@10.0.0.1 "kubectl get jobs -n hydra --sort-by=.metadata.creationTimestamp | tail -5"

# Check audit buffer on Node 8
ssh root@40.160.32.80 "ls -la /opt/hydra/audit/"
ssh root@40.160.32.80 "cd /opt/hydra/audit && git status"
```

**Fix:**
```bash
# Manual push
ssh root@40.160.32.80 "cd /opt/hydra/audit && git add -A && git commit -m 'manual audit push' && git push"
```

---

## Emergency Procedures

### Full Rollback to Clio

If HYDRA is completely down and cannot be recovered quickly, fall back to the
previous single-agent system (Clio) running on Aaron's Mac Mini.

**Steps:**

1. **Disable HYDRA Slack apps:**
   - Go to api.slack.com/apps
   - For each of the 9 agent apps, revoke tokens or disable the app
   - This prevents ghost responses if HYDRA comes back unexpectedly

2. **Re-enable Clio:**
   - On the Mac Mini, start the Clio agent process
   - Verify Clio is responding in Slack

3. **Notify the team:**
   - Post in #general: "HYDRA is temporarily offline. Clio is back as a fallback.
     Use @Clio for all AI assistant needs."

4. **Investigate and fix HYDRA** before switching back

5. **Switch back to HYDRA:**
   - Stop Clio on Mac Mini
   - Re-enable HYDRA Slack app tokens
   - Restart the gateway
   - Verify all 9 agents are connected
   - Notify the team

---

### Node 8 Hardware Failure

If Node 8 has a hardware failure that OVH cannot resolve quickly:

1. **Agents go silent** -- Slack connections drop, all agents stop responding
2. **K3s marks NotReady** -- `kubectl get nodes` shows ovh-node-8 as NotReady
3. **Fallback to Clio** (see above) while provisioning a replacement

**Provisioning a replacement:**

1. Order a new OVH server (ADVANCE-3 or equivalent)
2. Install Ubuntu 24.04 LTS
3. Join to K3s cluster as agent node with `dedicated=hydra:NoSchedule` taint
4. Install Docker
5. Clone the hydra repo to `/opt/hydra/`
6. Restore secrets from Vault
7. Run the deploy script: `/opt/hydra/scripts/deploy.sh`
8. Update DNS/firewall as needed
9. Verify all 9 agents reconnect

Estimated recovery time: 2-4 hours (depending on OVH server provisioning speed).

---

### Secret Rotation (Bulk)

If a security incident requires rotating all secrets:

1. **Rotate Slack tokens** (all 9 apps):
   ```bash
   # For each agent
   # 1. Regenerate at api.slack.com/apps
   # 2. Update Vault
   vault kv put secret/hydra/{agent-id}/slack bot_token=xoxb-... app_token=xapp-...
   ```

2. **Rotate `OPENROUTER_API_KEY`:**
   - Issue a new key at https://openrouter.ai/keys
   - Update Vault: `vault kv put secret/hydra/openrouter api_key=sk-or-...`

3. **Wait for ESO sync** (typically 30-60 seconds)

4. **Restart everything:**
   ```bash
   ssh root@40.160.32.80 "docker restart hydra-sandbox"
   ```

5. **Verify all agents reconnect:**
   ```bash
   ssh root@40.160.32.80 "docker exec hydra-sandbox openclaw agents list"
   ```

6. **Audit**: Check hydra-audit repo for any unauthorized activity during the incident window.

---

### Quick Reference Card

| Task                        | Command                                                        |
|-----------------------------|----------------------------------------------------------------|
| Check containers            | `ssh root@40.160.32.80 "docker ps"`                           |
| Restart gateway             | `ssh root@40.160.32.80 "docker restart hydra-sandbox"`        |
| View gateway logs           | `ssh root@40.160.32.80 "docker logs hydra-sandbox --tail 50"` |
| Check OpenRouter reachable  | `ssh root@40.160.32.80 "docker exec hydra-sandbox curl -sS -o /dev/null -w '%{http_code}\n' https://openrouter.ai/api/v1/models"` |
| List agents                 | `ssh root@40.160.32.80 "docker exec hydra-sandbox openclaw agents list"` |
| Check Slack connections     | `ssh root@40.160.32.80 "docker logs hydra-sandbox 2>&1 \| grep 'socket mode'"` |
| Check node in K3s           | `ssh root@10.0.0.1 "kubectl get node ovh-node-8"`             |
| Manual audit push           | `ssh root@40.160.32.80 "cd /opt/hydra/audit && git add -A && git commit -m 'manual' && git push"` |
| Full recreation             | `ssh root@40.160.32.80 "docker rm -f hydra-sandbox && /opt/hydra/scripts/deploy.sh"` |
