# HYDRA Operational Runbook

> **Version**: 1.0 | **Date**: 2026-03-22
>
> Step-by-step procedures for operating, troubleshooting, and recovering the HYDRA system.
> Intended audience: Aaron and anyone with SSH access to Node 8.

---

## Table of Contents

1. [Common Operations](#common-operations)
2. [Troubleshooting](#troubleshooting)
3. [Emergency Procedures](#emergency-procedures)

---

## Common Operations

### Check System Status

```bash
# Check all Docker containers are running
ssh root@40.160.32.80 "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# Expected output:
# NAMES            STATUS          PORTS
# hydra-sandbox    Up X hours      127.0.0.1:18789->18789/tcp
# cliproxyapi      Up X hours      127.0.0.1:8317->8317/tcp
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

### Restart CLIProxyAPI

```bash
ssh root@40.160.32.80 "docker restart cliproxyapi"

# Verify
ssh root@40.160.32.80 "docker logs cliproxyapi --tail 20"
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

### View CLIProxyAPI Logs

```bash
ssh root@40.160.32.80 "docker logs cliproxyapi --tail 50"
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

5. **Is CLIProxyAPI healthy?**
   ```bash
   ssh root@40.160.32.80 "docker logs cliproxyapi --tail 20"
   ```
   If CLIProxyAPI is down, the agent receives the message but cannot generate a response.

**Resolution**: Usually one of: restart gateway, add agent to channel, or fix CLIProxyAPI.

---

### CLIProxyAPI Down

**Symptoms**: Agents receive messages but never respond, or respond with error messages.

**Diagnosis:**

```bash
ssh root@40.160.32.80 "docker ps | grep cliproxyapi"
ssh root@40.160.32.80 "docker logs cliproxyapi --tail 30"
```

**Common causes and fixes:**

| Cause                          | Fix                                               |
|--------------------------------|---------------------------------------------------|
| Container crashed              | `docker restart cliproxyapi`                      |
| OAuth token expired            | Usually auto-refreshes; if not, see below         |
| Account-level token revocation | `docker exec -it cliproxyapi claude-login`        |
| Anthropic API outage           | Wait for Anthropic to resolve; check status.anthropic.com |

**Manual OAuth re-login (last resort):**
```bash
ssh root@40.160.32.80
docker exec -it cliproxyapi claude-login
# Follow the OAuth flow in your browser
# Then restart
docker restart cliproxyapi
```

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
ssh root@40.160.32.80 "docker exec hydra-sandbox curl -s http://localhost:8317/health"
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

**CLIProxyAPI tokens:**
CLIProxyAPI auto-refreshes OAuth tokens. If auto-refresh fails:
```bash
ssh root@40.160.32.80 "docker exec -it cliproxyapi claude-login"
ssh root@40.160.32.80 "docker restart cliproxyapi"
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

2. **Rotate CLIProxyAPI OAuth:**
   ```bash
   ssh root@40.160.32.80 "docker exec -it cliproxyapi claude-login"
   ```

3. **Wait for ESO sync** (typically 30-60 seconds)

4. **Restart everything:**
   ```bash
   ssh root@40.160.32.80 "docker restart cliproxyapi && docker restart hydra-sandbox"
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
| Restart CLIProxyAPI         | `ssh root@40.160.32.80 "docker restart cliproxyapi"`          |
| View gateway logs           | `ssh root@40.160.32.80 "docker logs hydra-sandbox --tail 50"` |
| View proxy logs             | `ssh root@40.160.32.80 "docker logs cliproxyapi --tail 50"`   |
| List agents                 | `ssh root@40.160.32.80 "docker exec hydra-sandbox openclaw agents list"` |
| Check Slack connections     | `ssh root@40.160.32.80 "docker logs hydra-sandbox 2>&1 \| grep 'socket mode'"` |
| Check node in K3s           | `ssh root@10.0.0.1 "kubectl get node ovh-node-8"`             |
| Manual audit push           | `ssh root@40.160.32.80 "cd /opt/hydra/audit && git add -A && git commit -m 'manual' && git push"` |
| Full recreation             | `ssh root@40.160.32.80 "docker rm -f hydra-sandbox && /opt/hydra/scripts/deploy.sh"` |
