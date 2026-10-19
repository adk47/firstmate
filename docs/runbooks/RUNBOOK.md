# HYDRA Operational Runbook

> **Version**: 1.0 (created 2026-03-22; revised periodically since)
>
> Step-by-step procedures for operating, troubleshooting, and recovering the HYDRA system.
> Intended audience: Aaron and anyone with SSH access to Node 8.

---

## Table of Contents

1. [Common Operations](#common-operations)
2. [Deploy](#deploy)
3. [Maintenance Windows](#maintenance-windows)
4. [Troubleshooting](#troubleshooting)
5. [Sentry issue triage](#sentry-issue-triage)
6. [Emergency Procedures](#emergency-procedures)

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

### muso CLI (main gateway)

The `muso` binary (github.com/Muso-AI/muso-cli) is version-pinned by deploy.sh
(`MUSO_CLI_VERSION`, Step 4d.6) and its policy config is rendered into
`/root/.config/muso/` on every deploy. Its runtime env is NOT deployed — it
lives in `/etc/openclaw/main.env` and is manually provisioned.

`/root/.config/muso/` is deploy-owned: every deploy overwrites
`approvers.txt`, `bulk-exclude.txt`, and `config.json` from the **operations
workspace** muso-ops-admin config on node-8
(`/opt/hydra/workspaces/operations/skills/muso-ops-admin/config/` — the same
files muso-admin-api.sh enforces; server-owned live policy, NOT synced from
git). To change approvers, edit that source dir on node-8 — hand-edits to the
rendered files are silently lost on the next deploy.

One-time provisioning (deploy.sh warn-checks these and tells you if they're
missing):

```bash
ssh root@40.160.32.80
# Edit this file without printing secret values. admin_u@muso.ai must exist in
# the DEV users table with the admin role; its password must be dev-specific.
sudoedit /etc/openclaw/main.env

# Required keys:
# MUSO_ADMIN_EMAIL=...          # legacy wrappers; production only
# MUSO_ADMIN_PASSWORD=...
# MUSO_PROD_ADMIN_EMAIL=...     # muso-cli scoped production credential
# MUSO_PROD_ADMIN_PASSWORD=...
# MUSO_DEV_ADMIN_EMAIL=admin_u@muso.ai
# MUSO_DEV_ADMIN_PASSWORD=...   # new dev-only password; never reuse prod
# MUSO_ENV=prod
# MUSO_NONINTERACTIVE=1
# MUSO_STATE_DIR=/var/log/muso-ops
systemctl restart openclaw-gateway-main
```

Why each var matters:
- `MUSO_ENV=prod` — muso defaults to the dev environment; without this every
  unqualified agent call would target dev. Explicit `--env dev` still wins.
- `MUSO_ADMIN_EMAIL/PASSWORD` — legacy production-only credentials for
  integrations that have not migrated to `MUSO_PROD_ADMIN_*` yet.
- `MUSO_PROD_ADMIN_EMAIL/PASSWORD` — the explicitly scoped production pair
  used after muso-cli v0.11+ is released and pinned. The legacy pair then
  remains a prod-only CLI fallback.
- `MUSO_DEV_ADMIN_EMAIL/PASSWORD` — the dev-only admin identity used after
  muso-cli v0.11+ is pinned. Until that release is installed, do not run a dev
  auth check from this host: v0.10 still reads the generic production pair.
- `MUSO_NONINTERACTIVE=1` — guarantees muso never blocks on a confirmation
  prompt if an exec ever allocates a PTY.
- `MUSO_STATE_DIR=/var/log/muso-ops` — shares the merge-guard and
  DELETE-counter state with muso-admin-api.sh and merge-landing-watchdog.sh;
  without it the incident guards split into two blind halves.

Verify:

```bash
ssh root@40.160.32.80 'muso version --json | jq -r .version'   # == MUSO_CLI_VERSION pin
ssh root@40.160.32.80 'muso health --env prod'                  # exit 0
ssh root@40.160.32.80 'systemd-run --quiet --wait --collect --pipe --setenv=HOME=/root -p EnvironmentFile=/etc/openclaw/main.env /usr/local/bin/muso api GET /admin/credit-requests/counts --env prod --json >/dev/null'
ssh root@40.160.32.80 'ls -l /root/.config/muso/'               # config.json, approvers.txt, bulk-exclude.txt
ssh root@40.160.32.80 'bash /opt/hydra/scripts/muso-prewrite-hook.sh GET /x prod; echo rc=$?'  # rc=0 when codex healthy
```

After muso-cli v0.11+ is released and pinned here, dev/QA connection quota
reset is idempotent and keeps Connection rows intact:

```bash
sender_user_id='12345'
requester_email='developer@example.com'
ssh root@40.160.32.80 systemd-run --quiet --wait --collect --pipe \
  --setenv=HOME=/root -p EnvironmentFile=/etc/openclaw/main.env \
  /usr/local/bin/muso api GET /admin/credit-requests/counts --env dev --json >/dev/null
ssh root@40.160.32.80 systemd-run --quiet --wait --collect --pipe \
  --setenv=HOME=/root -p EnvironmentFile=/etc/openclaw/main.env \
  /usr/local/bin/muso connections quota reset --env dev \
  --user "$sender_user_id" --requester "$requester_email"
```

The CLI gate and backend handler both refuse this operation outside dev. If
dev login returns `User Not Found!`, provision/fix the dev application user
and role; the database `db-muso-core-admin` ExternalSecret is unrelated to
application login.

### Troubleshooting

- **Deploy fails at Step 0 (drift check)** — the server has files the repo doesn't. See briefing in deploy log for the list. For an edited tracked file use `scripts/sync-from-server.sh <target> --apply --only <path>`; it pulls tracked files only, so a file the repo never tracked must be `scp`ed, reviewed (no secrets) and `git add`ed by path. Commit, then retry the deploy.
- **Deploy fails at Step 4a (pre-flight)** — rsync `--delete` would remove server files not in the repo. See briefing in the deploy log for the list and recovery steps.
  - If the flagged file is a stray scratch directly under `workspaces/qa/` (e.g. the historical `workspaces/qa/seven_days_ago` from a QA auto-review), it is now swept automatically on the next merge of a QA-reviewed PR by `.github/workflows/qa-pr-merged.yml` (→ `scripts/qa-clean-merge-scratch.sh`, which deletes only depth-1 files that are neither tracked nor matched by `RSYNC_EXCLUDES`). To unblock the current deploy immediately, still `rm` the file on node-8 and rerun — the sweep races the deploy and only guarantees the *next* one is clean.
- **Deploy fails at Step 4d (plugin install)** — npm install failed for a specific plugin. The error message names the plugin and its stderr. Fix the `package.json` or dependencies and retry. Set `HYDRA_CONTINUE_ON_PLUGIN_FAIL=1` to see all plugin failures at once.
- **Deploy fails at Step 5b (k8s apply)** — rollback yaml is at `/tmp/hydra-rollback-deployments.yaml` on node-8. To revert: `kubectl apply -f /tmp/hydra-rollback-deployments.yaml -n hydra`
- **Deploy fails at Step 7 (smoke test)** — check the smoke test output in the deploy log. Entries prefixed `FAIL:` are hard-gate failures and block the deploy; entries prefixed `WARN:` are soft-gate warnings and are informational only. The smoke test exits 0 unless `FAILURES > 0`.
- **Slack alerts not firing** — the `HYDRA_SLACK_WEBHOOK` secret is missing or empty. The presence check in `deploy.yml` surfaces this as a `::warning::` annotation on every workflow run (non-blocking — deploys still proceed). To fix: get the `#hydra-heartbeat` webhook URL from the Slack app settings and run `gh secret set HYDRA_SLACK_WEBHOOK --repo Muso-AI/hydra`. If you want the presence check to be a hard gate instead of a warning, change `::warning::` → `::error::` and add `exit 1` in the "Check SLACK_WEBHOOK presence" step.

---

## Maintenance Windows

Any planned work that stops or churns the gateways — openclaw bumps, state surgery,
a Node upgrade — fights the fleet's autonomic self-healing. `openclaw-watchdog`
(2-min cron) restarts a stopped gateway; `codex-token-refresh` restarts both to load
a token; `hydra-peer-labels` RPCs a down gateway; and the alert-only watchdogs page
for a fleet that is down on purpose. Before the maintenance flag this meant hand-
moving ~10 `/etc/cron.d` files and stopping timers per window (easy to get wrong — a
missed watchdog restarted a gateway mid-archive on the 2026-07 7.1 window and
corrupted the first state archive).

**One command opens/closes a window.** `scripts/hydra-maintenance.sh` drops a single
flag file (`/run/hydra-maintenance`) that every fleet-health watchdog checks and
stands down for:

```bash
# Deployed at /opt/hydra/scripts/hydra-maintenance.sh (not on PATH — use the full path).
/opt/hydra/scripts/hydra-maintenance.sh start "openclaw 7.1 upgrade" --ttl 2h   # watchdogs stand down; posts #clio_devops
/opt/hydra/scripts/hydra-maintenance.sh status                                  # ACTIVE/EXPIRED/none + reason + remaining
# ... do the work (stop gateways, archive, deploy) ...
/opt/hydra/scripts/hydra-maintenance.sh stop                                    # watchdogs re-arm; posts #clio_devops
```

**Fail-safe by construction — you cannot leave the fleet permanently unguarded.**
The TTL is enforced by the *readers*, not a background job: an expired flag is
ignored, so a forgotten `stop` re-arms every watchdog automatically once the TTL
passes. `/run` is tmpfs, so a reboot also clears it. A malformed or unreadable flag
reads as "not in maintenance" — a broken flag never disarms the fleet. The worst
case is a bounded blind window you explicitly asked for.

**What it does and does not do.** It only suppresses the autonomic watchdogs'
restart/page actions. It never stops a service itself (you still stop gateways
explicitly) and never touches systemd `Restart=always` (crash-recovery is still
wanted mid-window). Deploys and `rollback.sh` are intentional, operator/CI-driven,
and deliberately NOT gated — a deploy must converge and an auto-rollback must fire.

**Which watchdogs honor it** (fleet-health): `openclaw-watchdog`,
`codex-token-refresh`, `codex-keepalive`, `stuck-lane-watchdog`,
`cron-health-watchdog`, `fallback-swallow-watchdog`, `caroline-rag-index-watchdog`,
`provision-peer-labels`, and `intercom-intake-watchdog` (the last shells out to
`hydra-maintenance is-active`).

**Which do NOT** (business/prod — a fleet window must not blind you to a real Muso
prod incident, a sales lead, or a legal deadline): every script listed, with its
reason, in `scripts/tests/fixtures/maintenance-guard-exempt.txt` (the authoritative
list). This split is enforced: any new
`*-watchdog.{sh,py}` that is neither guarded nor listed there fails CI
(`scripts/tests/maintenance-guard-drift.bats`), so exempting one is always a
conscious decision.

Canonical use is `docs/runbooks/UPGRADE-2026.7.1.md` (Phase 1 opens the window
before stopping the gateways; Phase 4 closes it).

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

### Retiring the hand-placed edge MemoryLow drop-in (MUS-6310)

`MemoryLow=6G` on `openclaw-gateway-edge` was first applied by hand on node-8
(8 Oct) and is now generated by `scripts/install-aux-units.sh` into the managed
`override.conf` (edge only). Two hand-placed leftovers remain: both
carry the same 6G, so they change nothing once the managed line lands (the
`/run` one outranks `/etc` drop-ins, but the value is identical), and the
installer deliberately does not remove them. Retire them after the deploy.

**Steps 2 and 3 are node-8 writes. They need Nick's explicit go and are run by
the Chief of staff, not by an engineer.**

```bash
# 1. AFTER Deploy HYDRA — confirm the managed drop-in now owns the value
systemctl cat openclaw-gateway-edge            # override.conf must show MemoryLow=6G
systemctl show openclaw-gateway-edge -p MemoryLow -p DropInPaths

# 2. Remove the two leftovers. NEVER `systemctl revert` — it also deletes the managed
#    override.conf and strips edge's ExecStartPre self-heal + ExecStartPost reindex hook.
rm -f /etc/systemd/system/openclaw-gateway-edge.service.d/50-memorylow.conf
rm -f /run/systemd/system.control/openclaw-gateway-edge.service.d/50-MemoryLow.conf
systemctl daemon-reload

# 3. Verify: value unchanged, single owner
systemctl show openclaw-gateway-edge -p MemoryLow     # MemoryLow=6442450944
systemctl show openclaw-gateway-edge -p DropInPaths   # ONLY …/override.conf
```

**Never run `systemctl revert openclaw-gateway-edge`.** It removes every
drop-in for the unit, including the managed `override.conf`.

**Rollback window.** Until the PR that added the managed line has been stable
on node-8 for a deploy cycle, do not run step 2: the leftover
`50-memorylow.conf` is the only thing that keeps the 6G protection if that PR
is reverted. If step 2 has already run and the PR must be reverted, restore a
fallback *before* re-deploying the old installer, then verify:

```bash
install -d /etc/systemd/system/openclaw-gateway-edge.service.d
printf '[Service]\nMemoryLow=6G\n' > /etc/systemd/system/openclaw-gateway-edge.service.d/50-memorylow.conf
systemctl daemon-reload
systemctl show openclaw-gateway-edge -p MemoryLow     # MemoryLow=6442450944
```

This is also a node-8 write: Nick's explicit go, run by the Chief of staff.

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

**Mercury Bank API token (Finance):**

Symptom: `HTTP 401 {"errors":{"errorCode":"noTokenInDBButMaybeMalformed"}}` from
`GET https://api.mercury.com/api/v1/accounts`. That error means "Mercury has no
record of this token" — a **revocation at the vendor**, not a malformed
request. Confirm by sending deliberate garbage: it returns the identical 401.
The Finance agent's daily CIB report and Liza's cash forecasts are blocked
until it is replaced.

Only a human can fix it — there is no self-heal, because minting a token needs
the Mercury dashboard:

```bash
# 1. Mercury dashboard -> Settings -> API tokens -> new READ-ONLY token.
#    Authorized: Aaron (U7RP6HKUZ) and Liza (U0A8CCTTAAG) via the Finance agent.
# 2. Install it. `read -rs` keeps the token off the screen AND out of history
#    (bash historises the command, not what read consumed), and printf is a
#    builtin so it never appears in argv / `ps`.
ssh root@40.160.32.80
read -rsp 'Mercury token: ' MERCURY_TOKEN; echo
printf 'MERCURY_API_KEY=%s\n' "$MERCURY_TOKEN" \
  | install -m 600 -o root -g root /dev/stdin /opt/hydra/secrets/mercury.env
unset MERCURY_TOKEN
# 3. Verify — exit 0 means Mercury accepted it:
bash /opt/hydra/scripts/lib/ensure-mercury-token.sh --check
bash /opt/hydra/scripts/lib/ensure-secret-perms.sh --check
```

> ⚠️ Do **not** install it with a heredoc (`install ... <<'EOF'` with the token
> inline). bash's `cmdhist` stores a multi-line command — heredoc body included —
> as a single history entry, so that form plants the live token in
> `/root/.bash_history`: another persistent plaintext copy on the same box, which
> is the whole failure mode this credential already had once.

Detection: `/etc/cron.d/mercury-token-watchdog` runs
`scripts/mercury-token-watchdog.sh` daily at 08:45 UTC and pages #clio_devops
(Nick + Aaron) until it is fixed. `scripts/lib/ensure-mercury-token.sh --check`
is the read-only detector — 0 works / 1 broken / 2 could not evaluate.

**Silencing the daily page while a replacement token is pending.** Minting one
needs a human in a browser, so the reminder can outlive its usefulness. Snooze
it for a bounded window rather than disabling the cron (which the next deploy
reinstalls anyway, via `install-aux-units.sh`):

```bash
# node-8 — acknowledge for 30 days
printf '%s' "$(date -u -d '+30 days' +%s)" > /var/lib/hydra/mercury-token-snooze-until
# cancel early
rm -f /var/lib/hydra/mercury-token-snooze-until
```

While it is in effect the watchdog still runs, still probes, and still writes
the verdict to `/var/log/mercury-token-watchdog.log` — only the Slack post is
skipped. The window **expires on its own**, and a recovered token clears the
file, so a re-revocation later pages immediately. Two things it deliberately
does not do: it does not silence the "health UNKNOWN" page (a broken *probe* is
new information nobody acknowledged), and a corrupt or empty file counts as no
snooze at all — a half-written acknowledgement fails toward the alarm.

The expiry is the point. The table below is what an unbounded "yeah, we know"
looks like after the fact.

The credential lives at `/opt/hydra/secrets/mercury.env` (0600, perms held by
`ensure-secret-perms.sh`). **Do not move it back under
`workspaces/finance/.secrets/`**: that tree is inside every agent's sweep radius
and is rsync-mirrored into the private `Muso-AI/hydra-audit` git repo, which is
how the previous token leaked verbatim into the cmo/cto/clio session
transcripts and got committed (2026-08-04).

History — this token has been revoked twice, and the second death went
unnoticed for ~8 weeks because nothing watched it:

| Token | Worked | Dead by |
|---|---|---|
| A | 2026-04-28 → 04-29 | 2026-05-01 |
| B | 2026-05-24 → 06-10 | 2026-07-13 (surfaced 08-03) |

---

### Codex Auth Invalidated / Silent Fallback

**Symptoms**: codex agents (`openai/gpt-5.6-sol`/`-luna` via the codex
agentRuntime, ChatGPT OAuth) silently degrade to their OpenRouter fallback
(gpt-5.6-luna, then haiku); logs show
`auth refresh request timed out after 10s` or `authentication token has
been invalidated`; agents appear to be "running twice" as concurrent
refreshes race. Usually hits multiple/all codex agents at once.

**Background:** Codex OAuth credentials must live in ONE canonical store —
the `main` agent at `/root/.openclaw-main/agents/main/agent/auth-profiles.json`
— with every other agent's `auth-profiles.json` + `auth-state.json` a symlink
to it. OpenAI codex uses single-use rotating refresh tokens under a
per-profile lock (upstream #26322). If any agent gets an independent
(copied/seeded) auth store, parallel refreshes mutually invalidate the token
and take down ALL codex agents (incident 2026-05-29: 6 agents on Sonnet
fallback for hours). See CLAUDE.md §"Codex / OAuth auth is centralized".

**Diagnosis:**
```bash
ssh root@40.160.32.80
# Names any agent store that is NOT a symlink to canonical (exit 1 = drift)
/opt/hydra/scripts/lib/ensure-codex-auth.sh --check
# Confirm the silent-fallback signature in the logs
journalctl -u openclaw-gateway-main --since '-2h' \
  | grep -iE 'auth refresh request timed out|authentication token has been invalidated'
```

**Remediation:**
```bash
ssh root@40.160.32.80
# 1. Stop the gateway so no agent refreshes mid-repair.
systemctl stop openclaw-gateway-main.service

# 2. Converge every agent store back onto canonical. (On runtime <= 2026.6
#    this re-symlinks the JSON stores; on >= 2026.7 it delegates to
#    codex-auth-sync.sh, which reseeds the main-agent sqlite row + every
#    agent's chatgpt-mode codex-home/auth.json and deletes per-agent rows.)
/opt/hydra/scripts/lib/ensure-codex-auth.sh

# 3. Re-auth into the CANONICAL main store. Without --agent this writes to
#    the configured-default agent (clio), NOT main — pass --agent main.
#    All THREE accounts must be logged in (a third was linked 2026-07-28).
openclaw models auth login --provider openai-codex --agent main  # aaron@muso.ai
openclaw models auth login --provider openai-codex --agent main  # aarondkaufman@gmail.com
openclaw models auth login --provider openai-codex --agent main  # aaronkaufman@me.com
# Verify all three landed in BOTH namespaces before moving on:
openclaw --profile main models auth list | grep -c '^- openai:'                    # expect 3
jq -r '.profiles|keys[]' /root/.openclaw-main/agents/main/agent/auth-profiles.json \
  | grep -c '^openai-codex:'                                                        # expect 3

# 3b. Runtime >= 2026.7 ONLY: the login wrote a runtime store, but canonical
#     (agents/main/agent/auth-profiles.json) + the derived stores must be
#     reconverged after ANY re-auth. If the login landed somewhere other than
#     the canonical JSON, copy the fresh profile into it first, then:
/opt/hydra/scripts/lib/codex-auth-sync.sh

# 4. Verify stores are clean, then restart.
/opt/hydra/scripts/lib/ensure-codex-auth.sh --check
systemctl restart openclaw-gateway-main.service
```

**Rollback:** pre-repair auth stores are backed up to
`/root/codex-auth-backups/` (timestamped). If re-auth makes things worse,
restore the most recent backup into the canonical `main` path, re-run
`ensure-codex-auth.sh` to re-symlink, and restart.

**Prevention:** the `ensure-codex-auth.sh` self-heal + the codex-health
watchdog (fail-loud on `authentication token has been invalidated`) landed
fleet-wide via PR #376. NEVER copy/seed a per-agent codex `auth-profiles.json`.

---

### Codex Token Lapse (`token_expired`) — pure OAuth expiry, re-auth only

**Symptoms**: fleet on `openrouter/openai/gpt-5.6-luna`; logs show
`authentication token is expired` (`auth error code: token_expired`) on the
codex OAuth route (`chatgpt.com/backend-api/codex` on runtime <= 2026.6;
`wss://api.openai.com/v1/responses` on >= 2026.7). Crucially **all three guards are CLEAN**
(`ensure-codex-{auth,refresh-lock-shared,version-pinned}.sh --check` exit 0) and
`refresh_token_reused`/`invalid_api_key` are 0 — this is NOT fan-out, NOT the
refresh race, NOT #90925. It is the OAuth credential itself lapsing (single-use
rotating refresh token; upstream openclaw#57399, wontfix), ~every 10 days.

**Root cause of why it lapses AND why the old re-auth command is broken:** hydra
keeps the bundled `openai` plugin DISABLED to dodge #90925 — but that plugin owns
BOTH the refresh-on-use machinery AND the device-code login flow. So nothing
auto-refreshes codex, and `openclaw models auth login --provider openai-codex
--device-code` fails with **"No provider plugins found"** (the `codex` plugin
serves the model but never owned the OAuth flow; `openai-codex` is a retired id;
`--agent main` is invalid). There is no `openclaw models auth refresh` command.

**Recovery (primary — browser-free, what actually works):** refresh the token
ourselves via the out-of-band grant, then restart so the gateways load it:
```bash
ssh root@40.160.32.80
/opt/hydra/scripts/lib/codex-oauth-refresh.sh        # backs up + POSTs grant_type=refresh_token
                                                     # for both accounts; --dry-run to preview
systemctl restart openclaw-gateway-main openclaw-gateway-edge
# verify: a real codex turn returns gpt-5.6-sol (NOT a fallback):
openclaw --profile main agent --agent ceo --message "Reply with one word: pong"
```

**Recovery (fallback — only if `codex-oauth-refresh.sh` reports `invalid_grant` /
`refresh_token_invalidated`, i.e. the refresh-token chain is dead):**
```bash
/opt/hydra/scripts/lib/codex-reauth.sh              # prints a device URL + code
/opt/hydra/scripts/lib/codex-reauth.sh --dry-run    # preview, mints nothing
```
It drives the codex CLI's own `login --device-auth` (binary vendored inside the
pinned `@openclaw/codex`), then merges into canonical, shreds the scratch
credential, syncs to all agent stores and restarts. The account owner only has to
open the URL and approve the code. Add `--verify-chain` to spend one rotation
proving `codex-oauth-refresh.sh` can keep the new token fresh.

> **Do NOT transiently enable the `openai` plugin to get a device login.** The
> obvious command, `openclaw models auth login --provider openai-codex
> --device-code`, fails **"No provider plugins found"** — that plugin owns the
> flow and is disabled AND absent from `plugins.allow`, so `plugins enable openai`
> is itself refused ("blocked by allowlist"). Forcing it back on reintroduces
> #90925 while main self-restarts on memory pressure every ~40-60min, i.e. a
> near-certain fleet-wide `invalid_api_key` mid-window. A hand-rolled curl to
> `auth.openai.com/oauth/device/code` is also a dead end — Cloudflare answers 403.
> (Verified end-to-end 2026-07-27; this block previously recommended exactly the
> enable-plugin path and it does not work.)

**Prevention (the durable fix):** the twice-weekly `codex-token-refresh.timer`
(Sun+Wed 04:00 UTC → `scripts/codex-token-refresh.sh` → `codex-oauth-refresh.sh` +
gateway restart) keeps the ~10-day token always fresh (steady-state trough ~6.5d,
surviving a single missed run) with one brief quiet-hour restart each.
`scripts/codex-keepalive.sh` (cron every 15m) is the SAFETY NET — it reads expiry
straight from the canonical auth store (`auth-profiles.json` `.expires`; NOT the
CLI — 2026.7.x `models status --json` carries no expiry data at all, which
silently blinded the pre-7.1 parse during the 2026-07-14 401 storm) and pages
#clio_devops BEFORE the cliff (`:hourglass_flowing_sand: Codex OAuth token
expiring`) if the scheduled refresh keeps failing. If it cannot read an expiry
at all it pages `Codex keepalive BLIND` instead of skipping. (The watchdog's
`token_expired` page is REACTIVE, after the 401s.) NOTE: `models status --check`
always exits 1 here — it flags the disabled `openai` provider as "missing"; it
is NOT a codex-health signal. Both wired via `install-aux-units.sh`.

---

### Codex Usage Cap / Account Rotation (`usage limit`) — subscription capped, switch accounts

**Symptoms**: fleet on `openrouter/openai/gpt-5.6-luna`; fallback notices carry
`You've reached your Codex subscription usage limit. Next reset in N days`. All
guards CLEAN, zero 401s — auth is fine, the ACTIVE subscription's quota is
exhausted. sol/luna are model variants on ONE subscription, so the model-level
fallback chain can never "try the other account" (2026-07-21 incident: aaron@
capped at 100% while the paid standby idled fresh).

> **FIRST, before believing any of that: measure. Then check whose signature it is.**
>
> ```bash
> /opt/hydra/scripts/lib/codex-quota-probe.sh --all       # real per-account quota
> ```
>
> This asks the Codex backend directly (`codex app-server` JSON-RPC
> `account/rateLimits/read`) and takes ~7s per account. It is the ONLY
> authoritative source — everything derived from rollouts is account-blind.
>
> Then ask whether the cap signature is even about the account we run:
>
> ```bash
> jq -r '.auth.order.openai[0]' /opt/hydra/openclaw-main.json   # openclaw's head profile
> cat /var/lib/hydra/codex-active-account                       # OUR active account
> ```
>
> **These are two different rotation systems on two different surfaces.** Ours
> drives `codex-home/auth.json` (the codex agentRuntime). openclaw's drives
> `auth.order.openai` for the `[agent/embedded]` path and rotates profiles
> itself. openclaw's per-profile rate-limit cooldown caps at **5 minutes**, then
> the profile returns to the FRONT of the order — so an exhausted
> `auth.order[0]` emits the cap signature about **every 75 seconds forever**,
> regardless of which account we made active.
>
> On **2026-08-06** that produced 143 cap lines in 3h from aaron@muso.ai at 100%.
> The keepalive read them as "our active account is spent", rotated the state
> file (which changed nothing), burned the rotate cooldown, and paged
> `:no_entry: no rotation target left — every alternate account is known-capped`
> while gmail sat at **4%** and me.com at **0%**. The twice-daily usage report
> agreed with the false page, because it inferred standby numbers from the
> fleet-freshest rollout instead of measuring them.
>
> If the probe shows a healthy account and `auth.order[0]` is the capped one,
> **this is not a quota incident** — reorder `auth.order.openai` least-loaded
> first in the repo config and deploy. Do NOT edit `openclaw-*.json` on the box:
> out-of-band writes trip the write-audit watcher and are reverted by the next
> rsync. `codex-quota-refresh.sh` pages when the head profile is measured-capped.

**Auto-recovery (default)**: `codex-keepalive.sh` (15-min cron) has TWO
triggers for `scripts/lib/codex-account-rotate.sh --auto`, and BOTH now decide
on the account's own MEASURED quota (`/var/lib/hydra/codex-usage/<key>.measure.tsv`,
written every 20 min by `codex-quota-refresh.sh`), never on a fleet-wide
rollout snapshot:
- **Proactive** (preferred): the active account's measurement shows a window
  ≥95% used (`CODEX_KEEPALIVE_ROTATE_AT`) with its reset >60 min away —
  rotates BEFORE the cap error ever fires, skipping the degraded window.
- **Reactive** (backstop): the cap signature in the journal — but only after
  checking the active account's measurement. If that reads healthy (under 25
  min old), the signature is somebody else's and the keepalive says so instead
  of rotating; see the preface above.

The rotation writes the active-account state file
(`/var/lib/hydra/codex-active-account`, deploy-proof: outside the rsync tree,
re-resolved by `codex-auth-sync.sh` on every heal), appends the
active-account **ledger** (`/var/lib/hydra/codex-usage/active-account.log`, so
a later snapshot can be attributed to whoever was actually active when it was
emitted), re-syncs all runtime stores, drain-restarts both gateways, pages
#clio_devops with the measured evidence for both sides.

**Guards, and what each exit code actually means** — these are NOT
interchangeable, and treating them as one is what produced the false
2026-08-05 page:

| rc | meaning | what to do |
|----|---------|-----------|
| 3 | a rotation ran inside the 120-min cooldown | **no quota claim at all.** Wait, or `--force`. |
| 4 | no other usable profile in canonical (missing/expired token) | structural — `codex-reauth.sh` / `codex-oauth-refresh.sh` |
| 7 | every alternate is **measured** capped | genuine: ride OpenRouter until the earliest measured reset |
| 8 | no alternate has a **fresh measurement** | **the collector is the problem, not the quota.** Check `/var/log/codex-quota-refresh.log` and `/etc/hydra/codex-quota-probe.disabled`; or rotate deliberately with `--allow-unmeasured`. |

Only **rc 7** means the subscriptions are spent. **rc 8 means we cannot see
them** — do not wait it out. `--allow-unmeasured` permits an UNKNOWN target
(and the page says the target was unverified); only `--force` will select one
we measured as capped.

**Quota windows are NOT a fixed set**: OpenAI removed the 5h window ~Jul 12
2026 ("temporarily", undocumented — may return); since then the weekly window
arrives as `primary` with `secondary:null`. All parsing keys on
`window_minutes`, never on primary/secondary position — re-verify the snapshot
shape on codex behavior changes.

**Manual**:
```bash
/opt/hydra/scripts/codex-usage-report.sh                          # who is active, quotas
/opt/hydra/scripts/lib/codex-account-rotate.sh --to <email> [--force]  # switch now
cat /var/lib/hydra/codex-active-account                           # current choice
```
Precedence everywhere: `CODEX_AUTH_PRIMARY` env > state file > baked default
(aaron@muso.ai). The standby's tokens stay fresh because
`codex-oauth-refresh.sh` refreshes ALL `openai-codex:*` profiles.

---

### Codex Session Revoked Upstream (`token_invalidated`) — needs a browser

**Symptoms**: the whole codex fleet falls back to `openrouter/openai/gpt-5.6-luna`
with `reason=auth_permanent` and detail *"Your access token could not be
refreshed. Please log out and sign in again."*; a direct API call returns 401
`token_invalidated`. **`refresh_token_reused` is 0** and **all three `ensure-*`
guards read CLEAN** — nothing is structurally wrong, so no guard can see this.

**Do not confuse this with the refresh race below.** Until 2026-07-27 the race
detector also matched the generic `reason=auth_permanent` marker, so this
incident paged as "Codex refresh-token race" and cost ~1h chasing lock
convergence that was, and stayed, converged. The counters are now split; if you
see a race page, confirm a non-zero `refresh_token_reused` before believing it.

**Cause**: OpenAI ended the OAuth session for that account — a sign-in
elsewhere, a password change, an admin action. External and unpreventable. The
refresh chain dies with it, so `codex-oauth-refresh.sh` answers
`refresh_token_invalidated` ("Your session has ended") and there is **no
browser-free recovery**.

**Triage** (distinguishes it from every neighbouring class):
```bash
journalctl -u openclaw-gateway-main --since "30 min ago" --no-pager | grep -c refresh_token_reused   # 0 => not the race
/opt/hydra/scripts/lib/ensure-codex-auth.sh --check                  # CLEAN => not fan-out
/opt/hydra/scripts/lib/ensure-codex-version-pinned.sh --check        # CLEAN => not #90925
/opt/hydra/scripts/lib/codex-usage.sh                                # quota left => not the cap
```

**Remediation**:
1. If another account still has quota, restore service FIRST — it needs no human:
   `/opt/hydra/scripts/lib/codex-account-rotate.sh --auto`
2. Then re-auth the dead account: `/opt/hydra/scripts/lib/codex-reauth.sh`
   (device URL + code for the account owner; merges, syncs, restarts).

**Caution — a token probe cannot certify health.** A `wss://` handshake and a
plain HTTPS POST to `/v1/responses` both 401 for a credential that is serving
production fine (the HTTP one misleadingly says `Missing scopes:
api.responses.write`). They reliably prove a token is DEAD, never that it is
alive. The only positive check is a real turn:
`openclaw --profile main agent --agent ceo --message "Reply with one word: pong"`
plus zero `model-fallback/decision` lines in the window.

---

### Codex Refresh-Token Race (`refresh_token_reused`) — cross-process

**Symptoms**: the WHOLE codex fleet falls back to
`openrouter/openai/gpt-5.6-luna` with `reason=auth_permanent`; logs show
`OpenAI Codex token refresh failed (401)` with `code: refresh_token_reused`.
**Confirm a non-zero `refresh_token_reused` count** — `auth_permanent` alone is
the generic auth-dead marker and more often means the session-revocation class
above.
Crucially, **`ensure-codex-auth.sh --check` is CLEAN** — this is NOT the
fan-out incident above. Do not be misled into hunting for a stray store.

**Background:** hydra runs TWO codex gateway processes — `--profile main`
(state `/root/.openclaw-main`) and `--profile edge` (Caroline, state
`/root/.openclaw-edge`) — that share the ONE canonical refresh token via
symlink. openclaw serializes refresh with an O_EXCL lock under
`<stateDir>/locks/oauth-refresh/`, but each process derives that path from its
OWN state dir, so main's and edge's locks never collide. At the 5-min
pre-expiry margin both processes refresh at once; one rotates the single-use
token and wins the disk write, the loser POSTs the now-spent token → 401
`refresh_token_reused`, and the only freshly-minted valid token is clobbered →
fleet dead until interactive re-auth. (Upstream openclaw#3611 is this exact
cross-state-dir case, Closed with no fix; #26322 fixed only the
single-state-dir case.)

**Diagnosis:**
```bash
ssh root@40.160.32.80
journalctl -u openclaw-gateway-main -u openclaw-gateway-edge --since '-2h' \
  | grep -iE 'refresh_token_reused|OpenAI Codex token refresh failed|reason=auth_permanent'
/opt/hydra/scripts/lib/ensure-codex-auth.sh --check                 # EXPECT: clean (this is the tell)
# Are the two processes' refresh-lock dirs converged onto one physical dir?
/opt/hydra/scripts/lib/ensure-codex-refresh-lock-shared.sh --check  # exit 1 = NOT converged
```

**Remediation (recover now — re-auth is unavoidable, the token is spent):**
```bash
ssh root@40.160.32.80
# 1. Re-auth. Use codex-reauth.sh — do NOT reach for `openclaw models auth login`.
#
#    `openclaw models auth login --provider openai-codex --device-code` FAILS on
#    this fleet with "No provider plugins found": the bundled `openai` plugin owns
#    the device-code flow and hydra keeps it DISABLED and off `plugins.allow` to
#    dodge #90925 (enabling it reroutes the fleet primary onto the api-key
#    endpoint → fleet-wide `invalid_api_key`). Same note is on the watchdog page
#    for this signature and in codex-reauth.sh's own header. This runbook used to
#    print that command here; following it costs you time in an active outage.
#
#    codex-reauth.sh drives the codex CLI's OWN `login --device-auth` (the
#    vendored binary under @openclaw/codex), then merges into canonical, shreds
#    the scratch credential, syncs derived stores and restarts. It prints a URL
#    and a code for Aaron to complete in a browser.
/opt/hydra/scripts/lib/codex-reauth.sh
# Verify all three accounts are present in BOTH namespaces before moving on:
openclaw --profile main models auth list | grep -c '^- openai:'                    # expect 3
jq -r '.profiles|keys[]' /root/.openclaw-main/agents/main/agent/auth-profiles.json \
  | grep -c '^openai-codex:'                                                        # expect 3
# 2. Converge the lock dirs so it can't recur, then restart both gateways.
#    (codex-reauth.sh already restarts; this is the belt-and-braces path if you
#    ran the convergence check above and it reported NOT converged.)
/opt/hydra/scripts/lib/ensure-codex-refresh-lock-shared.sh
systemctl restart openclaw-gateway-main.service openclaw-gateway-edge.service
# 3. Verify: codex serving itself again, no fallback banner.
journalctl -u openclaw-gateway-main -f | grep model-fallback
#   want: candidate_succeeded ... candidate=openai/gpt-5.6-sol  (NOT ...gpt-5.6-luna reason=auth_permanent)
```

**Prevention (mechanical):** `ensure-codex-refresh-lock-shared.sh` runs in the
ExecStartPre of both gateways (via `openclaw-pre-start-heal.sh`) to converge the
lock dirs; `openclaw-watchdog.sh` (every 2 min) pages #clio_devops on the
`refresh_token_reused`/`auth_permanent` signature (scanning BOTH main and edge)
and again if `--check` ever reports the convergence broke. **Re-verify the
sidecar-lock realpath behavior on every openclaw bump** — the fix depends on
openclaw realpath-resolving the lock dir at acquire time.

---

### Codex Plugin Floated Off Pin / api-key-route 401 (#90925)

**Symptoms**: the WHOLE codex fleet (gpt-5.6) falls back to
`openrouter/openai/gpt-5.6-luna`; logs show `401 Unauthorized: Incorrect API key
provided: sk-...` / `invalid_api_key` on the **`api.openai.com/v1/responses`**
URL with `reason=auth`. Crucially, **BOTH `ensure-codex-auth.sh --check` AND
`ensure-codex-refresh-lock-shared.sh --check` are CLEAN** — this is neither the
fan-out nor the refresh-race incident. The URL tell is VERSION-DEPENDENT:
- **runtime <= 2026.6 (codex 2026.5.27)**: `chatgpt.com/backend-api/codex/responses`
  = the OAuth route (good); `api.openai.com/v1/responses` = the regressed
  api-key route (#90925).
- **runtime >= 2026.7**: BOTH modes target `api.openai.com/v1/responses` — the
  transport is the tell: WebSocket (`wss://…`, in codex app-server stderr) =
  OAuth; a plain HTTP 401 `invalid_api_key` with the placeholder `sk-hydra…`
  key = the api-key path, which on 7.x means an agent's `codex-home/auth.json`
  regressed to `auth_mode:"apikey"` — run `scripts/lib/codex-auth-sync.sh`
  (then `--check`) and restart, and only then suspect a plugin float.

**Background:** codex is pinned in LOCKSTEP to the runtime
(`scripts/lib/codex-version.sh`; from 2026-06-16 to 2026-07-14 it was held
BELOW the runtime at `2026.5.27` because `@openclaw/codex@2026.6.x`'s "OpenAI
route unification" (upstream #90925 / #90448) routed `openai/gpt-5.5` to the
api-key endpoint — fixed in 2026.7.1, staging-verified). hydra is OAuth-only
(only a PLACEHOLDER `OPENAI_API_KEY`), so any api-key-routed call 401s.
`deploy.sh` pins codex, but a manual `openclaw plugins install
@openclaw/codex@<v> --force` between deploys floats it off the pin and stays
floated (incident 2026-06-19). The token is NOT the problem here — re-auth
does nothing.

**Diagnosis:**
```bash
ssh root@40.160.32.80
journalctl -u openclaw-gateway-main -u openclaw-gateway-edge --since '-15min' \
  | grep -iE 'invalid_api_key|Incorrect API key|api.openai.com/v1/responses'
# Is codex floated off the pin? (exit 1 + names the profile/version)
/opt/hydra/scripts/lib/ensure-codex-version-pinned.sh --check
/opt/hydra/scripts/lib/ensure-codex-auth.sh --check                 # EXPECT clean
/opt/hydra/scripts/lib/ensure-codex-refresh-lock-shared.sh --check  # EXPECT clean
```

**Remediation (re-pin — NO re-auth, the token is valid):**
```bash
ssh root@40.160.32.80
# Re-pin both profiles to the canonical version, then restart to load it.
/opt/hydra/scripts/lib/ensure-codex-version-pinned.sh    # re-pins where drifted
systemctl restart openclaw-gateway-main.service openclaw-gateway-edge.service
# Verify: codex serves itself again on the OAuth route.
journalctl -u openclaw-gateway-main -f | grep model-fallback
#   want: candidate_succeeded ... candidate=openai/gpt-5.6-sol  (NOT ...gpt-5.6-luna)
openclaw agent --agent clio --model openai/gpt-5.6-sol -m "reply pong" --json   # provider=openai model=gpt-5.6-sol
```

**Prevention (mechanical):** `ensure-codex-version-pinned.sh` runs in the
ExecStartPre of both gateways (via `openclaw-pre-start-heal.sh`) — a float
self-heals on the next restart; `openclaw-watchdog.sh` pages #clio_devops on the
`invalid_api_key`/`Incorrect API key` signature (main+edge) and again if `--check`
reports version drift. The pinned version lives ONCE in
`scripts/lib/codex-version.sh` (deploy + heal + watchdog all read it). **NEVER
`plugins install`/`update` codex off the pin**; bump `codex-version.sh` (revert to
runtime lockstep) only once #90925 ships fixed in a core release we run.

**Pin-clean api-key 401s = COMPACTION, not a float (do NOT re-pin — it's a no-op).**
If you see `invalid_api_key` / `Incorrect API key: sk-hydra…` but
`ensure-codex-version-pinned.sh --check` is **CLEAN**, this is NOT #90925. Tell them
apart by the record's context: a float 401s on **every** codex turn fleet-wide; the
compaction case is scoped to `[agent/embedded] skipping codex app-server compaction for
non-manual trigger` → raw OpenAI 401 → `[compaction-diag] … trigger=cli_budget` and a
paid fallback **for that one compaction**, while normal turns keep serving on OAuth.
Root cause in openclaw 2026.7.1: `runCliTurnCompactionLifecycle` converted the intentional
"codex app-server owns automatic compaction" result into
`fallbackToContextEngine:true`; the legacy context engine then summarized through the
placeholder API-key route. This is not version drift. Hydra backports the upstream 7.2
behavior with `scripts/patch-openclaw-codex-native-compaction.sh`: the intentional
native-owned result is now a clean no-op, so local compaction does not reach the legacy
summarizer or OpenRouter. Deploy reapplies the fail-closed patch after every runtime pin
check and stops if its compiled-code anchor drifts. Keep the liveness detector
conservative: fallback-decision records have no compaction/run identity, so filtering them
after the fact can either hide real fallbacks or recreate the false page under concurrency.

- **Watchdog**: the `:rotating_light: floated off pin` alert now runs the pin `--check`
  and only cries "float" when the pin actually **drifted**. A pin-clean 401 (the
  compaction path) is **log-only — it does NOT page** (benign, self-recovering, no
  action needed; it also never consumes the api-key cooldown, so a genuine float still
  pages). Only `float` and `unverifiable` page. (`codex_apikey_route_verdict` in
  `scripts/lib/codex-health.sh`; dispatch in `scripts/openclaw-watchdog.sh`.)
- **Write-gate**: `codex_health_gate` (admin/Stripe write-health) likewise pin-gates the
  api-key signal — a **float or unverifiable** pin still refuses writes (fail-closed), but
  a **compaction-only** (pin-clean) 401 no longer over-blocks writes on a healthy fleet.
- **`compaction.model` is NOT the fix**: openclaw docs say *do not set
  `agents.defaults.compaction.model` on Codex-backed agents* (it emits an "override
  ignored" warning). Native Codex owns automatic compaction; leave it unset.

> **Related — Codex OAuth token lapse** (the original 2026-06-19 trigger, distinct
> from the api-key-route bug above): logs show `401 ... authentication token is
> expired. Please try signing in again.` on the **OAuth** route
> (`chatgpt.com/backend-api/codex/responses` on <= 2026.6;
> `wss://api.openai.com/v1/responses` on >= 2026.7). This IS a token problem — the access
> token lapsed and refresh stopped renewing it. Fix = FIRST try the browser-free
> path, `/opt/hydra/scripts/lib/codex-oauth-refresh.sh` then
> `systemctl restart openclaw-gateway-main openclaw-gateway-edge`; only if that
> reports `invalid_grant`/`refresh_token_invalidated` (the chain is dead) run
> `/opt/hydra/scripts/lib/codex-reauth.sh` for a device-code login. Do NOT reach for
> `openclaw models auth login --provider openai-codex --device-code` — it fails
> "No provider plugins found" here (the `openai` plugin owns that flow and is
> disabled). All three accounts must end up logged in (aaron@muso.ai +
> aarondkaufman@gmail.com + aaronkaufman@me.com — a third was linked 2026-07-28).
> The watchdog now pages on this `authentication token is expired` signature too.

---

### AI Healer (DR Layer 2) — `scripts/dr-ai-healer.sh`

**What it is:** the escalation layer above the code-level healers. When a CRITICAL
codex/gateway signature persists across 3 consecutive watchdog ticks (~6 min — the
ExecStartPre healers and the watchdog auto-restart have already had their chance), or
immediately on a definitive code-heal failure (gateway restart FAILED, crash loop),
`openclaw-watchdog.sh` fires `dr-ai-healer.sh --trigger <signature>` in the background.

**How it works — "AI-decides, code-executes":** the healer gathers a bounded,
secret-scrubbed diagnostics bundle (guard `--check` outputs, `systemctl status`,
filtered journal tails), makes one direct OpenRouter call per round — at most
`DR_MAX_ROUNDS` (default 2) calls per session — (default model
`openai/gpt-5.6-luna` — the api-key route survives codex OAuth death and needs no
openclaw machinery), and asks it to pick ONE action from a **closed allowlist**. The
model's output is data; a bash `case` executes it. Unknown action, malformed JSON,
confidence < 0.6, curl failure, or a missing key all collapse to `no_action` (page-only).

| action | maps to | runs |
|---|---|---|
| `heal_auth_fanout` | Codex Auth Invalidated (above) | `ensure-codex-auth.sh` + restart |
| `oauth_refresh` | Codex Token Lapse (above) | `codex-oauth-refresh.sh` + restart |
| `converge_refresh_lock` | lock-convergence drift (manual trigger only — a `codex_refresh_race` escalation is page-only, since the spent token is unhealable) | `ensure-codex-refresh-lock-shared.sh` + restart |
| `repin_codex` | Floated Off Pin (#90925, above) | `ensure-codex-version-pinned.sh` + restart |
| `auth_sync_7x` | 7.x derived stores stale/apikey-mode | `codex-auth-sync.sh` + restart |
| `restart_gateways` | gateway down, no codex signature | `reset-failed` + restart main+edge |
| `tighten_secret_perms` | secret perms drift | `ensure-secret-perms.sh` + restart |
| `no_action` | anything else / unhealable | page-only |

A spent refresh token (`refresh_token_reused` / `invalid_grant`) is **unhealable by
design** — the prompt says so and the correct outcome is a `no_action` page telling you
to device-code re-auth (see the Refresh-Token Race section above).

**Guardrails:** kill switch `/etc/hydra/dr-ai-healer.disabled` (touch to disable),
single-flight lock, 60-min cooldown between sessions, max 3 sessions/24h (then it
pages "budget exhausted" instead of acting), max 2 decide→execute rounds per session.
Every outcome (recovered / no_action / did-not-recover / abort) pages #clio_devops
with real `<@UID>` mentions for Nick + Aaron and the AI's rationale.

**Manual / testing:**
```bash
# Dry-run: consults the AI, prints the chosen action, executes NOTHING,
# stamps no cooldown:
/opt/hydra/scripts/dr-ai-healer.sh --trigger manual --dry-run
# Disable / re-enable the whole layer:
touch /etc/hydra/dr-ai-healer.disabled
rm /etc/hydra/dr-ai-healer.disabled
# Watchdog-side escalation log:
cat /var/lib/hydra-dr/dr-ai-healer.log
```

---

### #prod-alerts Is Too Loud / Went Quiet (`prod-log-alert-watchdog`)

**Background.** `scripts/prod-log-alert-watchdog.sh` runs every 5 min from
`/etc/cron.d/prod-log-alert-watchdog`. Two behaviors live in it:

- **v2 — LIVE since 2026-08-05, the script's default.** An incident must PERSIST
  (~5 min measured in log-line time) or hit a fast-path bypass before it posts;
  eligible incidents roll up into one digest every 15 min; a classifier assigns
  severity and writes a one-line cause; **only a P0 mentions a human**, and only
  a paged digest wakes the devops agent.
- **v1 — the rollback path** (`PROD_LOG_ALERT_V2=0`): posts a fingerprint the
  FIRST time it is seen, then suppresses it for 6h. No persistence evidence, so
  a 30-second blip alerts exactly like an outage. This is the behavior Aaron
  asked us to stop on 2026-08-05. Kept for one release, then deleted.

The cron sets **no** `PROD_LOG_ALERT_V2` — the default lives only in the script,
so there is no cron-vs-script disagreement to debug. The cutover was a full
switch with no shadow period (Nick's call, 2026-08-05).

**Rollback to v1** — takes effect on the next tick, no deploy needed:

```bash
mkdir -p /etc/hydra
touch /etc/hydra/prod-log-alert-v1.enabled     # revert to first-sighting alerting
rm    /etc/hydra/prod-log-alert-v1.enabled     # back to v2
```

⚠️ **Use the flag file, not the cron file.** `/etc/cron.d/prod-log-alert-watchdog`
is regenerated wholesale by `install-aux-units.sh`, which `deploy.sh` runs on
every deploy — so a `PROD_LOG_ALERT_V2=0` line added there disappears the moment
you ship the fix-forward, i.e. exactly when you are relying on it. The flag file
is deploy-proof, same as `/etc/hydra/dr-ai-healer.disabled`. `PROD_LOG_ALERT_V2=0`
as an env var still works for a one-off manual run.

**First tick after the cutover.** The ledger (`incidents.json`) seeds itself once
from v1's `seen.json`, so errors already inside their 6h suppression stay
suppressed and the first digest is not a dump of everything currently firing.
That seeding happens only while the ledger does not exist.

**Too loud.**

| Symptom | Lever |
|---|---|
| Same benign line every few hours | Add it to `config/alert-exclude-patterns.txt` (**grep ERE**) — it is then dropped before fingerprinting. |
| Real but not worth 15-min granularity | Raise `PROD_LOG_ALERT_DIGEST_INTERVAL` (**seconds**, e.g. `1800` — not `30m`). |
| Alerts arrive too eagerly | Raise `PROD_LOG_ALERT_PERSIST_SECONDS` (**seconds**, default `300`). |
| Humans pinged too often | A mention needs all three: classifier `notify:page`, `severity:P0`, **and** blast radius (the same line across ≥`BLAST` deployments). Fast-path matches and single-deployment bursts deliberately do **not** page — both are computed from log text the reporter controls, so they would let crafted text supply its own corroboration. |
| Something real was auto-muted | A mute needs `severity:P2` **and** no corroboration, is capped at 3 per digest, and every muted line is printed under "Auto-muted for 24h". Clear one by deleting its key from `incidents.json`. |

⚠️ **Every numeric knob is seconds or a count — never a duration string**, and
most reject `0`. The lone duration is `PROD_LOG_ALERT_WINDOW` (a
`kubectl --since` value like `6m`). Both rules are enforced at startup with a
named error and exit 2, because both fail *silently* otherwise:

- `[ x -ge 15m ]` does not abort — it prints to stderr and evaluates false, which
  pins the digest to "never due" and holds every persisting incident
  indefinitely while the watchdog keeps reporting "nothing to post".
- `0` inverts a `>=` test into always-true. `PROD_LOG_ALERT_BLAST=0` stamps
  **every first sighting** with deterministic blast corroboration — the one leg
  of the page gate a crafted log line must not be able to forge. To disable a
  bypass, raise it out of reach (a huge `BURST`), never zero it.

`COOLDOWN`, `DIGEST_INTERVAL` and `MUTE_SECONDS` are the only knobs that accept
`0`, because there it means "off" in the direction of *more* alerting.

**Went quiet — is it broken or is prod fine?** In order:

1. `tail /var/log/prod-log-alert-watchdog.log`. `OK: nothing to post (eligible=…
   immediate=… resolved=… digest_due=…)` is healthy silence and tells you which
   gate held.
2. **`SELF-TEST FAIL` + `ABORT` means the detector is refusing to run** and NO
   alerting is happening. The message names which invariant broke; the overlap
   case ("counting TICKS, not log timestamps") means a code change turned the
   persistence gate into a no-op. Fix the code — do not disable the self-test.
3. Everything muted? `jq '[.[]|select(.muted_until)]|length' /var/lib/prod-log-alert/incidents.json`.
   Mutes are 24h TTLs set by the classifier; clear one by deleting its key.
4. Suspect the classifier is mis-judging: `touch /etc/hydra/prod-alert-classifier.disabled`.
   Digests keep posting, unclassified and with no mentions — visibility fails
   OPEN, paging fails CLOSED. Nothing else needs changing.

**State.** `/var/lib/prod-log-alert/incidents.json` — the ledger, one entry per
live incident: `first_ts`/`last_ts` (kubelet log time, the persistence span),
`total`, `state`, `posted_at`, `post_count`, `severity` (the classifier's last
verdict, kept for forensics — nothing reads it back), `muted_until`. Plus
`last-digest` and v1's `seen.json`. All are safe to delete: the next tick
rebuilds them, at the cost of re-alerting once. Entries are dropped after 3
ticks unseen, so the file tracks the live incident set, not history.

---

### Agent Can't See a Recently-Shipped Skill (stale skill catalog)

**Symptom:** an agent ignores a skill it was told to use, or "can't find" a skill that IS
deployed — e.g. CMO won't invoke `muso-streams-lookup`, or the ship-kit
(`ship`/`babysit`/`reflect`) isn't invocable. The skill is present in
`/root/.openclaw-<profile>/skills/` and `openclaw --profile <profile> skills list` shows it
"ready", yet it's absent from the agent's injected `<available_skills>`.

**Cause:** the gateway daemon resolves the model-invocable managed-skills tier with the
profile-**blind** `resolveStateDir(process.env)`. If `OPENCLAW_STATE_DIR` is unset in the
daemon's env, it falls back to the legacy `/root/.openclaw/skills` (frozen ~2026-05-26,
pre-#336) and injects that stale catalog into EVERY agent. The `skills list` CLI masks it
because the CLI gets `--profile`; the long-running daemon does not. (Root-caused 2026-06-29.)

**Diagnose:**
```bash
# Is the pin in the daemon's actual process env? (env-file vars show here; OPENCLAW_PROFILE does NOT)
pid=$(systemctl show -p MainPID --value openclaw-gateway-main)
tr '\0' '\n' < /proc/$pid/environ | grep OPENCLAW_STATE_DIR   # expect /root/.openclaw-main
# Compare a FRESH session's catalog count vs the live skills dir
ls /root/.openclaw-main/skills | wc -l                        # live count
```

**Fix:** pin per-profile (NOT `shared.env`), then restart:
```bash
grep -q '^OPENCLAW_STATE_DIR=' /etc/openclaw/main.env || echo 'OPENCLAW_STATE_DIR=/root/.openclaw-main' >> /etc/openclaw/main.env
grep -q '^OPENCLAW_STATE_DIR=' /etc/openclaw/edge.env || echo 'OPENCLAW_STATE_DIR=/root/.openclaw-edge' >> /etc/openclaw/edge.env
systemctl restart openclaw-gateway-main   # wait healthy, then:
systemctl restart openclaw-gateway-edge
```
A fresh agent session then loads the live catalog. **Never `rm /root/.openclaw`** (a missing
`~/.openclaw` makes `resolveStateDir` fall to an empty dir → agents lose ALL managed skills).
`scripts/deploy.sh` now fails loud if the pin is missing and re-asserts it post-restart via
`/proc`. See CLAUDE.md "Each gateway MUST pin `OPENCLAW_STATE_DIR`".

---

### Release Announcements — nothing posted / duplicate / no highlights

**What runs**: `hydra-release-watch.timer` every 5 min →
`scripts/release-watch.sh` → tag + GitHub release via `scripts/release.sh` →
Block Kit post to #releases. Log: `/var/log/hydra-release-watch.log`.
State: `/var/lib/hydra-release/{repos,announced,highlights}`.

```bash
systemctl list-timers hydra-release-watch.timer
journalctl -u hydra-release-watch -n 100 --no-pager
# What the watcher believes shipped last, per repo:
#   last_run_id is the checkpoint; last_date drives the daily gate.
tail -50 /var/log/hydra-release-watch.log
cat /var/lib/hydra-release/announced/web-credits-next
```

**First question, always: was anything actually released?** A quiet channel is
the correct output on a day with no prod deploy. `NO_REPLY` in the log means
"checked, nothing new" — that is success, not a failure.

| Symptom | Cause | Fix |
|---|---|---|
| Every tick exits non-zero, `RELEASES_SLACK_CHANNEL is unset` | `/etc/hydra/releases.env` missing or lacks the channel id | Write `RELEASES_SLACK_CHANNEL=<id>` there. This is fail-closed **on purpose**: tags cannot be un-cut, so it refuses to publish releases nobody can see. |
| A repo never announces and the log is quiet | its commits carry no `H-DevOps / deploy` success status | Check `gh api repos/Muso-AI/<repo>/commits/<sha>/status`. No status = nothing authoritatively says that sha reached prod, so the watcher stays silent by design. auth is in this state until the companion H-DevOps change lands. |
| A repo never announces, log says `refusing to publish full history` | never released, so no prior tag and no state to bound the range | Seed once: `./scripts/release-watch.sh --repo=<key> --bootstrap=<ref>`. The next prod deploy is the first announced release. |
| `does not descend from the last announced` | someone re-ran an OLD deploy workflow run — a re-run keeps its original `headSha` but gets a fresh `createdAt` | Nothing to fix. The guard is correct: that run shipped old code, and announcing it would publish a bogus release. |
| `rollout still pending — waiting` | a deploy is genuinely in flight | Expected. It announces on the next tick once the rollout reports success. |
| `rollout unresolved (state='none'…)` | the dispatch succeeded but no `H-DevOps / deploy` status exists yet | Expected while a deploy is running. It announces once the rollout reports success. |
| `no resolved … rollout after <n>s` + `INDETERMINATE` + non-zero exit | past the grace window with no terminal state — either `pending` that never finished, or no record at all | Whether that sha reached prod is genuinely unknown, so the watcher refuses to guess in either direction. Inspect the H-DevOps run for that repo, then re-seed: `./scripts/release-watch.sh --repo=<key> --bootstrap=<sha currently live>`. |
| auth never announces | expected — auth is `enabled=0` until H-DevOps#2799 gives it a `H-DevOps / deploy` status writer | Flip the row to `1` in `scripts/lib/release-repos.sh` once that merges. |
| Post says `⚠️ plain-language highlights unavailable` | the highlights call failed — most often a missing/rotated OpenRouter key, otherwise a model or network error | The release IS announced and correct; only the plain-English layer is missing. Highlights are a **direct, tool-less HTTP call**, NOT an agent turn — the gateway is irrelevant here. Check `OPENROUTER_API_KEY` in `/opt/hydra/secrets/llm-provider-keys.json`, then the log line naming the failure. Never re-cut the tag to retry. |
| Release tagged + on GitHub, but no Slack post | delivery failed after publish (best-effort by design) | Confirm the devops bot is a member of #releases. The state file already advanced, so it will NOT re-post; announce manually if it matters. |
| Two posts for one release | should be impossible — state is written atomically and keyed on the shipped sha | Inspect `/var/lib/hydra-release/announced/<key>`; if `last_marker` is stale, the state file was reverted or the state dir was wiped. |
| Wrong version number (`.1`, `.2` suffixes) | expected: several prod releases landed the same day | `--auto-suffix` walks to the first free `.N`, checking local AND origin tags. |
| hydra posts nothing despite deploying several times | expected: hydra is `cadence=daily` | One roll-up per Europe/Rome day from 08:00. Log says `holding`. Held ticks record nothing, so the next cut covers everything. |
| A `daily` repo announced twice in one day | `last_date` in its state file was cleared or the clock/TZ moved | Check `last_date=` in `/var/lib/hydra-release/announced/<key>` against `TZ=Europe/Rome date +%F`. |

**Preview without touching anything** (safe on prod, tags and posts nothing):

```bash
./scripts/release-watch.sh --repo=web-credits-next --dry-run
```

Human logs go to **stderr**; stdout is the machine channel (`NO_REPLY`, or the
payload JSON). Pipe stdout alone to inspect the message.

**Mobile posts nothing, and that is correct.** `ios-app` / `android-app` are
`enabled=0` in `scripts/lib/release-repos.sh` because neither H-DevOps prod
lane reaches users: iOS stops at TestFlight, Android uploads to Play track
`alpha` as a **draft**. Announcing those as released would be false.

**Reverting to the old daily cut**: `systemctl disable --now
hydra-release-watch.timer && systemctl enable --now hydra-release.timer`.
Never run both — they would both tag the same day.

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

## Sentry issue triage

Sentry is reached through an MCP server registered on the **main** gateway, and
issues arrive as Slack alerts posted into a channel the CTO agent watches.

**This IS an unattended pipeline since 2026-09-02.** Slack alerts alone still
do not summon the agent (`requireMention: true` on the channel bindings; see
"Think before you add that mention" below), but `scripts/sentry-issue-watchdog.sh`
(cron `*/30`, `/etc/cron.d/sentry-issue-watchdog`) polls the three code-owning
projects, posts a digest to `#sentry-alerts`, and dispatches at most 1 issue per
tick / 3 per day to `cto` (PR #886). In that turn the `sentry-issue-triage`
skill classifies the issue and, under **Nick's standing autofix authorization**
recorded in the skill, acts on it without waiting for anyone:

| Verdict | What happens unattended |
|---|---|
| `code-fixable` | fix PR opened to `develop` (core-backend, web-credits-next) and **merged by the watchdog once QA's `qa-review` status is GO** (posted by QA's own App identity), CI is green and it is mergeable. **Prerequisite:** the repo is listed in `policies/qa-approval-policy.json` `app_repos`; until then QA's GO is host-posted, the watchdog refuses it, tags Nick, and **a human merges**. auth gets a PR to `main` and core-backend a `master` twin PR, both production and human-merged |
| `client-noise` | issue **archived in Sentry until escalating** with a reason comment - it leaves the inbox and the digest, and reopens itself on a spike |
| everything else | written diagnosis in the thread naming the owner; no write |

Nick is tagged (`<@U0AL36NADEY>`) in the issue's thread when the PR opens,
when the watchdog merges it after QA's GO (or when QA says NO-GO, once per
head), and when a human merges the twin / auth PR (merge-notify pass). The
agent never merges and never pushes a default branch; the CTO pre-push guard
is unchanged. **The merge never bypasses branch protection:** web-credits-next
`develop` requires 1 approving review, and QA approves with the host login
(`adk47`) today, the same login that authors the PR, so its formal approval
self-blocks there; the watchdog waits for a human approval (or QA on its App
identity once `policies/qa-approval-policy.json` `app_repos` lists the repo).
core-backend `develop` requires nothing and its PR checks are thin (the
qa-autoreview `dispatch` job and `test`), so QA's GO is most of its gate; red
CI after a GO tags Nick once per head instead of waiting silently. Off switches, deploy-proof:
`touch /etc/hydra/sentry-issue-watchdog.no-dispatch` (poll + digest, wake nobody),
`touch /etc/hydra/sentry-issue-watchdog.no-merge` (everything except the QA-gated
merge), or `touch /etc/hydra/sentry-issue-watchdog.disabled` (stop entirely).
The merge is bound to the reviewed head (`gh pr merge --match-head-commit`), reads
both classic protection and rulesets for a review requirement, and tags Nick
once if no QA review has started after 6h or if a base needs an approving review
it cannot supply. Ledger states in `/var/lib/hydra-sentry-triage/seen.jsonl`
(latest row per id decides):
`awaiting-approval` = diagnosed code-fixable, re-dispatched to open the PR
**only if the watchdog originated it** (its `dispatched.json` names the id and
the row carries a dispatch nonce from the watchdog's bounded per-issue
history, an exact match; a human's thread row has none and waits for that human) and for at most `SENTRY_WATCHDOG_MAX_ATTEMPTS`
(3) unattended runs, after which Nick is tagged once and it waits for a human;
`in-progress` = a turn holds the lease (older than 3h = a crashed run: ours is
re-dispatched, a human's is tagged once); any Step 3 class = triaged. The
engineering doctrine (classification taxonomy, the P0 rule, the project-to-repo
map, the twin-port rule, the authorization bounds) lives in the skill; this
section is only the wiring.

Org: `musoai` (`https://musoai.sentry.io`, region `https://us.sentry.io`).
Projects: `core-backend`, `credits-web-next`, `muso-auth`, `flutter`.

### Why no Sentry autofix has ever auto-merged — and the two things that fix it

Asked on 2026-09-22 ("make the CTO agent autofix `develop` on core-backend, not
just web-credits-next"). The premise is wrong in a useful way: **core-backend is
not behind web-credits-next.** Both repos run the same policy
(`scripts/lib/sentry-merge-policy.sh:16` maps both to `develop qa-gated`), both
are polled (`scripts/sentry-issue-watchdog.sh:125`), and the CTO agent opens
core-backend fix PRs (#9692, #9701, #9753 + twin #9754). Nothing about the
pipeline treats them differently. What is broken is the **last mile, in both
repos equally**, and it is two independent blockers, not one.

**Blocker 1 — the merge: one identity is playing author, reviewer and merger.**
`qa_creator_ok()` (`scripts/sentry-issue-watchdog.sh:1162-1192`) requires the
`qa-review` status creator to be in `policies/qa-approval-policy.json`
`.identity.bot_logins` **and** `!= MERGER_LOGIN`. On node-8 `gh api user` is
`adk47`; QA posts its GO as `adk47`; the PRs are *authored* as `adk47`. So the
gate refuses, correctly, every 30 minutes:

```
qa-merge: …/core-backend/pull/9753 qa-review GO posted by 'adk47' — not QA's App identity, not merging.
qa-merge: …/web-credits-next/pull/944 qa-review GO posted by 'adk47' — not QA's App identity, not merging.
```

This is the separation-of-duties rule from #907 working as designed — **do not
"fix" it by relaxing `qa_creator_ok` to accept `creator == merger`**, which is
exactly the self-approval loophole it exists to close. It also explains a second
symptom: `qa-pr-approve.sh` Guard 3c refuses these PRs outright
(`author_deny: ["adk47"]`, exit 12), and GitHub blocks self-approval anyway.
The root unblock is `.identity.app_repos` being `[]` and
`/opt/hydra/secrets/qa-bot-app.json` not existing — **the App was designed,
scripted and tested, but never registered.** See the checklist below.

Note the repos differ in what happens *after* the creator check passes:
core-backend `develop` has no classic protection (404) and no rulesets, so the
App alone unblocks it. web-credits-next `develop` requires 1 approving review
(`required_approving_review_count: 1`), so #944 is `BLOCKED` /
`REVIEW_REQUIRED` and needs QA's App approval to count as well. core-backend
`master` twins (#9754) are production and stay human-merged — that is correct
and must not change.

**Blocker 2 — the dispatch: 6 core-backend diagnoses are stranded forever.**
Separately from the merge gate, six core-backend issues sit at
`awaiting-approval` and **can never be re-dispatched**, so their fixes are never
even written. Two independent reasons, each sufficient:

1. *No dispatch nonce.* The origin check (`:966-993`) re-dispatches an
   `awaiting` row only if `dispatched.json` carries a nonce matching the row's
   `contract`. Nonces landed with #907 on 2026-09-04; these rows were written
   2026-08-25…09-01, **before the field existed**, so they read as
   "human-initiated, awaiting a human" and nothing will ever pick them up.
   Confirmed on node-8: all 6 have `contract: null`, and their `dispatched.json`
   entries are the only 24 of 55 with no `nonces` key.
2. *Not fresh.* Even with a nonce they would never re-enter the candidate list:
   the filter (`:792-796`) keeps an issue only if `substatus` is
   new/regressed/escalating **or** `firstSeen` is inside `NEW_WINDOW` (7d). All
   six are `ongoing` and 22–551 days old. Eligibility is intersected with the
   candidate list at `:1547-1551`, so they are dropped there regardless.

The affected rows (core-backend): `11A`, `11C`, `11D`, `K9`, `R6`, `RZ`.
web-credits-next has the same shape on `3S` and `41`. This is a **backlog
drain**, not a pipeline bug — the design deliberately refuses to land a
human-started diagnosis unattended, and equally deliberately does not chase
year-old `ongoing` issues. Draining it is a decision for Nick and Aaron, not a
silent code change. Two of these are worth a look on merit: `K9` (1550 events /
268 users, first seen 2025-03-19) and `R6` (978 / 78).

Today's two `needs-human` rows are **correctly classified** and are not part of
this: `CORE-BACKEND-107` (PgBouncer slot exhaustion) and `CORE-BACKEND-VD`
(OOM-killed feed-service workers) are both the feed-service incident. The fix is
in feed-service's read-session lifecycle and memory growth, not in core-backend
code, so "needs-human" is the right answer and no autofix should have been
attempted.

`skills-all/sentry-issue-triage/config/watchdog-exclude-patterns.txt` contains
**no core-backend exclusions** — every pattern targets browser/client noise in
credits-web-next. If anything the asymmetry runs the other way, which is why the
core-backend ledger has zero `client-noise` rows against credits-web-next's 29.

### Register the QA GitHub App (Aaron — org-admin, ~15 min, unblocks both repos)

This is the whole fix for Blocker 1 and it needs **no code change**: once
`qa-review` is posted by `muso-qa-bot[bot]`, the existing gate passes as
designed. The alternative — giving the watchdog a second merger identity
(a `muso-merge-bot` PAT) so `MERGER_LOGIN != adk47` — is **not** equivalent and
should not be used as a shortcut: it would make the merger distinct while
leaving *author and reviewer* the same account, so the GO would still be
self-attested, and it adds a second long-lived admin-capable credential on
node-8. The App fixes author/reviewer/merger in one move and holds
`contents: read` (never write), so approve is structurally not merge.

Aaron's steps, in order:

1. On a machine with a browser (not node-8):
   `python3 scripts/qa-bot-app-register.py --org Muso-AI`
   One click on "Create GitHub App". Writes `qa-bot-app.json` locally, 0600.
2. Install it — **on all three repos**, not just hydra as the script's own
   "Next steps" text says: `Muso-AI/hydra`, `Muso-AI/core-backend`,
   `Muso-AI/web-credits-next`.
3. `scp qa-bot-app.json root@40.160.32.80:/opt/hydra/secrets/qa-bot-app.json`
   then `chmod 600`, then
   `bash /opt/hydra/scripts/qa-bot-app-verify.sh --fix-installation-id`.
4. `bash /opt/hydra/scripts/qa-bot-app-verify.sh` — must be all PASS. `push:
   false` is **correct**; never broaden the App to `contents: write` to make a
   check go green.
5. PR the policy change (`policies/` is Aaron-owned, and
   `qa-approval-policy.json` is in `sensitive_paths_blocking`, so the bot
   refuses to approve this PR by design — a human merges it):
   set `.identity.app_repos` to
   `["Muso-AI/core-backend", "Muso-AI/web-credits-next"]`. Deploy.
   Leave `author_deny: ["adk47"]` alone; flipping it is a separate decision.
6. On web-credits-next only: confirm QA's App approval satisfies
   `required_approving_review_count: 1` on `develop`. If it does not, that repo
   still needs a human approval and only core-backend goes fully unattended.
7. Watch one tick: `/var/log/sentry-issue-watchdog.log` should stop printing
   `not QA's App identity` for the next GO.

Do **not** start by adding repos to `merge_gate_repos` — that makes `qa-review`
a required check, and GitHub never times out a required check that was never
reported, so a lost dispatch makes a PR permanently unmergeable. That list is a
separate, later decision (see its `_field_notes`).

**Meanwhile, #9753 and #9754 are waiting on a human.** #9753 (core-backend
`develop`, CORE-BACKEND-Q0) has been `CLEAN` with a QA GO since
2026-09-21T22:29Z and is safe to merge by hand — that is what happened to #9692
and #9701, both merged by `nsollazzo`. #9754 is its `master` twin: production,
`BLOCKED`, and human-merged by design — review it on its own merits. Merging
9753 by hand is the only thing that moves today; nothing else drains until the
App exists.

### The registration is runtime-only, therefore fragile — read this first

**It has already been destroyed once.** Registered 2026-08-25 12:59, gone by
2026-08-26 05:11. Root cause, from `/var/log/openclaw-legitimate-writes.log`
(which names every writer of the live config):

| Time | Writer | Result |
|---|---|---|
| 08-25 12:59:31 | `sentry-mcp-register` | registered |
| 08-26 04:40:49 | `deploy.sh` | `preserved 1 live MCP server(s)` |
| **08-26 05:11:15** | **`rollback`** | **destroyed** |
| 08-26 06:14:32 | `deploy.sh` | `preserved 0` |

Deploy run `32933062895` **attempt 1** failed, `deploy.yml`'s `Rollback on
failure` fired `rollback.sh`, and that script restored the profile configs with
a plain `cp` — no `.mcp.servers` preservation, unlike the forward path. Then
attempt 2 re-ran and succeeded, so **GitHub reported the whole run green**:
`gh run list` shows only the latest attempt. Use
`gh api repos/Muso-AI/hydra/actions/runs/<id> --jq .run_attempt` to see the
truth.

Fixed in `scripts/lib/sync-profile-config.sh` — one implementation, used by both
`deploy.sh` and `rollback.sh`, because two copies of that rule drifted and the
drift *was* the bug.

**Two things follow, and both matter more than the recipe below:**

1. **The source of truth is `/opt/hydra/secrets/sentry.env`** (root, `0600`,
   `SENTRY_API_TOKEN=...`), not the config. `scripts/lib/ensure-sentry-mcp.sh`
   re-derives the config entry from it before every gateway start
   (`openclaw-pre-start-heal.sh`) and `openclaw-watchdog.sh` pages if it drifts
   while running. If the file is missing, the healer says so and heals nothing —
   create it and the next start converges.
2. **The `tools.deny` scoping below is NOT durable and never was.**
   `sync_profile_config` preserves *only* `.mcp.servers`; `agents.list` is
   overwritten from the repo on every deploy. A runtime `jq` transform that adds
   `tools.deny` therefore survives until the next deploy — it lasted ~17 hours.
   **To persist, the deny list must be committed to `openclaw-main.json`**,
   which is Aaron-gated security surface (`workspaces/cto/SOUL.md:416`). The
   recipe below is still the correct *shape*; just do not mistake a green
   verification for a durable one. Re-verify after a deploy, which is the check
   that would have caught this.

`openclaw mcp set` is not an option here: it refuses any config containing the
legacy `plugins.installs` key, which this one still has. It would not have
helped anyway — it writes the same field a rollback overwrites.

### Register the Sentry MCP server

> **STOP — the Sentry MCP is DISABLED and this recipe will NOT stick (2026-09-11).**
>
> `scripts/lib/ensure-sentry-mcp.sh` carries `ESM_ENABLED`, which defaults to **0**.
> While it is 0 the healer **removes** `.mcp.servers.sentry` on every main gateway
> start (ExecStartPre) and the watchdog removes it again on its next tick. If you
> follow the recipe below, you will hot-reload an **unscoped** Sentry server into a
> fleet where every agent can reach the write-capable `sentry__update_issue`, and it
> will be torn out from under you minutes later — the worst of both worlds.
>
> **Why it is off:** PR #929 removed the `tools.deny: ["sentry__*"]` entries because on
> openclaw >= 2026.8 any non-core-safe deny silently disables that agent's entire
> native codex tool surface, including web search
> (`dist/selection-Bge6N4vD.js:789`). Disabling the registration keeps the write
> surface exactly where it was — zero — instead of widening it. **Aaron has not yet
> ruled** on whether fleet-wide `sentry__update_issue` access is acceptable.
>
> **To re-enable, do NOT run this recipe.** Flip `ESM_ENABLED` to `1` in
> `scripts/lib/ensure-sentry-mcp.sh` in a PR carrying Aaron's decision, and let the
> healer register it at the next start. That is the ONLY control: `.mcp` is absent
> from the repo configs, `scripts/lib/sync-profile-config.sh` preserves the live
> `.mcp.servers` across deploys, and the healer re-converges on every start — so a
> hand-written live registration is not durable state, it is a race you lose.
>
> Everything below is retained for the re-enable path and for understanding how the
> entry is shaped. It is **not** a live procedure while `ESM_ENABLED=0`.


`.mcp.servers` is deliberately absent from the repo configs so tokens never land
in git. `sync_profile_config()` in `scripts/deploy.sh` **preserves** the live
`.mcp.servers` across deploys, so this is a one-time runtime registration on
node-8, not a repo change.

```bash
# 1. Mint a Sentry token (Settings -> Auth Tokens). Minimum read-only scopes:
#      org:read  project:read  event:read
#    Add event:write ONLY if the agent should resolve/assign issues in Sentry.
#    Prefer an Internal Integration over a Personal token: personal-token scopes
#    are fixed at creation and the token dies if its creator leaves the org.

# 2. Register. Transport MUST be streamable-http (scripts/lint-openclaw-config.sh
#    rejects any stdio/mcp-remote entry at PR time; an mcp-remote subprocess trio
#    shares the gateway's process group and a reaper takes the gateway down).
#    The token lives ONLY inside this entry, i.e. in
#    /root/.openclaw-main/openclaw.json (root-readable). There is no env-var
#    indirection here: openclaw does not expand ${VARS} in mcp headers, so
#    putting SENTRY_MCP_TOKEN in main.env would be a dead line that misleads
#    whoever later tries to revoke the credential.
```

**There is deliberately no `openclaw mcp set` recipe here.** Every form of it
puts the credential in a process argument - either as `--arg` to jq or as the
JSON blob handed to `openclaw` - and `/proc/<pid>/cmdline` is world-readable
(0444), so any local process can read the token while that command runs.
Reading into a shell variable avoids the shell HISTORY, not argv. `mcp set` also
refuses this config (below), so the jq path is both the only safe form and the
only working one.

**`mcp set` will REFUSE this config as-is.** `openclaw-main.json` still carries
the legacy `plugins.installs` key, and `mcp set`/`mcp unset` reject any config
containing it (the runtime tolerates it; only the writer does not). See
`docs/lessons/openclaw-and-codex.md` -> "`mcp set`/`mcp unset` refuse configs
containing a legacy `plugins.installs` key". Until that key is migrated, add the
entry by hand instead - jq into a temp file, announce, atomic rename:

```bash
cfg=/root/.openclaw-main/openclaw.json
tmp=$(mktemp -p "$(dirname "$cfg")")
# FAIL-FAST. `jq ... > "$tmp"` truncates $tmp before jq runs, so a jq failure
# (malformed config, bad filter) leaves it EMPTY -- and an unguarded `mv` then
# replaces the LIVE gateway config with a zero-byte file, taking the gateway
# down. Reproduced: jq_rc=5, resulting config 0 bytes. Never announce or rename
# anything jq did not successfully produce.
# Read the token WITHOUT echo and pass it via the environment, never on the
# command line. A pasted literal lands in the interactive shell's history AND in
# jq's argv - and /proc/<pid>/cmdline is world-readable (mode 444), so the
# credential would be exposed to every local process for the life of the jq
# call. /proc/<pid>/environ is 0600, so `env.` is the safer channel.
read -rsp 'Sentry token (input hidden): ' SENTRY_TOKEN; echo
[ -n "$SENTRY_TOKEN" ] || { echo "no token entered - aborting" >&2; exit 1; }

# DO NOT ADD A PER-AGENT `tools.deny` HERE. This recipe used to register the
# server AND deny `sentry__*` to every agent except cto/qa in the same atomic
# write. On openclaw >= 2026.8 that deny is a SILENT KILL SWITCH for the whole
# codex native tool surface: `sentry__*` fails `isKnownCoreToolId`, so
# toolPolicyRestrictsHarnessNativeTools() marks the policy restricted,
# shouldEnableCodexAppServerNativeToolSurface() returns false on its first line,
# and the agent loses web_search, shell_tool, unified_exec, image_generation,
# browser_use, skill_search, memories and the rest of CODEX_RING_ZERO. That is
# incident 2026-09-10 (Scout told a user its web research provider was
# unavailable, five more agents downgraded silently). A narrowing `tools.allow`
# trips the identical path, and `alsoAllow` cannot exempt.
#
# There is no config-level way to scope an MCP server to a subset of agents:
# canonicalizeConfiguredMcpServer accepts no agent field and the schema calls
# these "Global MCP server definitions". The choice is "every agent sees it" or
# "nobody does" -- so the server is registered UNSCOPED and the sentry tools are
# visible fleet-wide. That is the accepted trade: the surface is read-heavy and
# its only mutator is `sentry__update_issue` (internal, reversible).
#
# `scripts/validate-config-matrix.sh` check #8 fails the build if a `sentry__*`
# deny ever reappears in a repo config. See docs/lessons/openclaw-and-codex.md.
#
# Tool ids are `<safeServerName>__<toolName>`; confirm the safe name in the
# gateway log (`[bundle-mcp] server key "<raw>" registered as "<safeName>"`)
# before trusting the `sentry__` prefix - a second server colliding on the safe
# name gets a `-2` suffix. The explicit ids still matter for the RECONCILIATION
# step below, which proves what the live catalog actually contains.

# NOTE the shape: agents live at `.agents.list` (an array of {id, ...}), NOT at
# `.agents`. `.agents` is an object {defaults, list}, so `.agents |= map(...)`
# iterates its VALUES and dies on `Cannot index array with string "id"`.
# `SENTRY_TOKEN=... jq` exports it for THIS command only. `read` makes a shell
# variable, and jq's `env.` sees only EXPORTED ones - without this prefix the
# header is written as "Sentry-Bearer " with no token, and (before the check
# below) that empty config was announced, renamed over the live file and the
# gateway restarted, leaving every Sentry request failing auth.
SENTRY_TOKEN="$SENTRY_TOKEN" \
jq --arg hdr "Sentry-Bearer" '
  .mcp.servers.sentry = {
    "transport": "streamable-http",
    "url": "https://mcp.sentry.dev/mcp",
    "headers": { "Authorization": ($hdr + " " + env.SENTRY_TOKEN) }
  }
' "$cfg" > "$tmp" || {
  rm -f "$tmp"; unset SENTRY_TOKEN; echo "jq failed - live config untouched" >&2; exit 1; }
unset SENTRY_TOKEN   # out of the shell as soon as it is in $tmp

# Validate before announcing or renaming: the server must be there with a real
# token, and NO agent may carry a sentry deny (see the kill-switch note above -
# a leftover one from the pre-2026.8 shape would silently strip that agent's
# native codex surface). Fail closed - a partial result must never reach the
# live config.
jq -e '
  (.mcp.servers.sentry.url == "https://mcp.sentry.dev/mcp")
  and (.mcp.servers.sentry.headers.Authorization
       | test("^Sentry-Bearer .+$"))          # non-empty token, not just the prefix
  and ([ (.agents.list // [])[]
         | ((.tools.deny // []) | map(select(startswith("sentry__"))) | length) ] | add == 0)
' "$tmp" >/dev/null || {
  rm -f "$tmp"; echo "server entry missing/invalid, or a sentry deny is present - aborting" >&2; exit 1; }

# Guard the ANNOUNCE like everything else: this block has no `set -e`, so an
# unguarded announce that fails (log unwritable or full) would still fall
# through to `mv`, changing the live config with no announcement - and the audit
# watcher then pages #clio_devops treating a legitimate write as out-of-band.
# On failure, remove $tmp: it holds the TOKEN and must not be left on disk.
if ! ANNOUNCE_SHA="$(sha256sum "$tmp" | awk '{print $1}')" \
     /opt/hydra/scripts/lib/announce-legit-write.sh sentry-mcp-register "$cfg"; then
  rm -f "$tmp"
  echo "announce-legit-write failed - live config untouched, temp file removed" >&2
  exit 1
fi

# Atomic rename - this is what actually registers the server. Nothing above
# changes the live config.
#
# It does NOT restart the gateway: openclaw watches this file and HOT RELOADS
# it. Observed 2026-08-25 registering the sentry server -- the journal shows
#   [reload] config change detected; evaluating reload (agents.list, mcp)
#   [reload] config hot reload applied (agents.list, mcp)
# with MainPID unchanged from the previous deploy. Do not wait for a restart
# that never comes, and do not restart by hand to "make it take".
mv "$tmp" "$cfg" || { rm -f "$tmp"; echo "rename failed - live config untouched" >&2; exit 1; }
echo "registered (unscoped by design); openclaw hot-reloads this file (no restart, PID unchanged)"
```

**RETIRED 2026-09-10: there is no deny list to reconcile.** This runbook used to
enumerate the catalog and prove that every non-cto/qa agent's `sentry__*` deny
COVERED every registered tool. On openclaw >= 2026.8 that deny is not a scoping
mechanism, it is a kill switch for the agent's entire codex native tool surface
(see the note in the registration block above and
docs/lessons/openclaw-and-codex.md). The denies were removed, the server is
registered unscoped, and `validate-config-matrix.sh` check #8 now fails the build
if one reappears.

The one thing still worth doing after registration is confirming the server
actually connected and that no stale deny survived:

```bash
openclaw --profile main mcp list | grep -i sentry
jq -r '[ (.agents.list // [])[]
         | select(((.tools.deny // []) | map(select(startswith("sentry__"))) | length) > 0)
         | .id ] | if length == 0 then "clean: no sentry denies"
                   else "STALE SENTRY DENY on: " + join(", ") end' \
  /root/.openclaw-main/openclaw.json
```

Note the catalog reaches further tools *through* `sentry__execute_sentry_tool`,
so any inventory written ahead of registration was always a guess. That is now
moot for policy purposes; it still matters for understanding what the token can
do, which is the section below.


### The Sentry MCP has never had an isolation boundary

The deny list that used to sit here was **defence in depth at best, and the
evidence below is why removing it in 2026-09 cost so little.** Two things are
true on this host today, and both were true while the deny was in force:

- every agent runs with `tools.exec.security: "full"` and `ask: "off"`, and no
  agent denies `exec`, so a prompt-injected agent can reach `/tools/invoke`
  through the shell and bypass `tools.deny` entirely. This repo already records
  the general form: *"`before_tool_call` hook as YOLO-mode safety -> silent
  no-op for exec; enforce at the bash boundary instead."*
- the token sits in `/root/.openclaw-main/openclaw.json`, which any exec-capable
  agent on the box can read and then use directly against the Sentry API, with
  or without the MCP server. **This is no longer hypothetical.** On 2026-08-26 a
  scan of agent state found the live token (71 chars, matching the last-4 shown
  in Sentry) inside the codex logs of `operations`, `qa` AND `clio` -
  `/root/.openclaw-main/agents/<id>/agent/codex-home/logs_2.sqlite`. Two of those
  three are agents the deny list exists to exclude. Rotating the token does not
  fix this; it only resets the clock, because the next read puts the new one
  there too. Treat the token's SCOPES as the only real bound.

So the deny only ever stopped ordinary and accidental use, and it demonstrably
did not stop the token from reaching three of the agents it excluded. The control
that actually bounds the blast radius is, and always was, the **token's own
scopes**:

- **The live token is WRITE-CAPABLE as of 2026-08-26, by Nick's explicit
  decision** ("I want hydra to do shit" - the agents should be able to act in
  Sentry, not only read it). Scopes:
  `alerts:read, alerts:write, event:read, event:write, member:read, org:read,
  project:read, project:releases, project:write, team:read`.
  An earlier version of this line said "do not mint `event:write`". That advice
  was overtaken; recording the reversal here rather than leaving the runbook
  contradicting the deployed reality.

  What that means concretely, given the token demonstrably reaches agents that
  are supposed to be denied (see below): a prompt-injected or compromised agent
  can resolve/assign/mutate production issues, modify projects and releases,
  and - the one worth watching - **modify or delete alert rules** (`alerts:write`).
  The last of those can disable the detection layer itself, which is a change
  you would not necessarily notice. If Sentry alerting ever goes quiet
  unexpectedly, check the alert rules before assuming the errors stopped.
- Accept that read access to production issue data (which includes customer
  emails and geo) is reachable by any compromised exec-capable agent here, and
  set the token's lifetime and rotation cadence with that in mind.

Real isolation would need a separate gateway/profile or a process boundary that
does not exist today. Do not claim it from this deny list.

#### The token is also in codex's bug-report buffer, by design

Measured 2026-08-27. Every agent's `codex-home/logs_*.sqlite` carries the live
Sentry token in plaintext:

```
DEBUG codex_core::session::handlers … op: RefreshMcpServers { config: … mcp_servers:
  Object {"sentry": Object {"url": …, "http_headers": Object {"Authorization":
  String("Sentry-Bearer <TOKEN>")}}}
```

`mcp.servers` is global in `openclaw.json`, so **every** agent receives the
refresh and logs the header - the `tools.deny` scoping above filters tool
*calls*, never credential *reads*. `qa` accumulated 50 such rows in 18 hours.

Three things are NOT true of this, and were checked rather than assumed:

- **It is not a non-root exposure.** The files are `0644`, but `/root` is `0700`,
  so nothing can traverse to them. Verified: `setpriv --reuid=1000 … head -c1`
  on one of these files returns unreadable.
- **It does not leave the box in a backup.** There is no state backup job - no
  timer on node-8, no `age`/S3 reference in this repo.
- **`RUST_LOG` cannot silence it.** This is the `bounded_feedback_logs` sink, not
  the tracing `EnvFilter`. It captures at TRACE (75k rows from `hyper_util` alone
  in one agent), well below the binary's `codex_core=info` default, and codex
  exposes no config key to disable it.

So it grants a root-capable agent nothing it did not already have - those agents
can read `/opt/hydra/secrets/sentry.env` directly.

**The risk that IS real: this is codex's feedback/bug-report buffer**
(`feedback_log_body`, `feedback_doctor_report`). Its purpose is being shipped to
OpenAI when someone files a report.

> **Never run a codex feedback or doctor report while a live credentialed MCP
> server is registered.** It will send the credential upstream.

The same applies to any future MCP server registered with an auth header, and to
any support bundle that sweeps `codex-home/`.

To scrub after a rotation (the rows survive the credential, so an old token stays
recoverable indefinitely otherwise):

```bash
# per DB: DELETE the matching rows, checkpoint, VACUUM, then re-grep the FILE
# BYTES of the main DB *and* its -wal/-shm sidecars.
#
# The byte-level re-check is the ground truth: a row count of 0 is not proof.
# And the -wal file is not optional -- a checkpoint can be refused while codex
# holds the DB, which leaves the token bytes sitting in logs_*.sqlite-wal while
# a main-DB-only grep prints a reassuring 0. Stop the gateways first if the
# checkpoint will not truncate.
python3 - <<'EOF'
import sqlite3, subprocess, glob, sys
tok = next(l.split("=",1)[1].strip() for l in open("/opt/hydra/secrets/sentry.env")
           if l.startswith("SENTRY_API_TOKEN="))
dirty = []
for f in glob.glob("/root/.openclaw-*/agents/*/agent/codex-home/logs_*.sqlite"):
    c = sqlite3.connect(f, timeout=30)
    c.execute("delete from logs where feedback_log_body like ?", (f"%{tok}%",))
    c.commit()
    # A refused checkpoint is a REPORTED failure, not a silent one: (busy, log,
    # checkpointed) -- busy != 0 means the WAL was not fully folded in.
    busy, wal_pages, ckpt_pages = c.execute("pragma wal_checkpoint(TRUNCATE)").fetchone()
    if busy:
        print(f"  !! {f}: checkpoint BUSY (wal={wal_pages} ckpt={ckpt_pages}) — stop the gateway and rerun")
    try:
        c.execute("vacuum")
    except sqlite3.OperationalError as e:
        print(f"  !! {f}: vacuum refused ({e}) — freed pages may still hold the token")
    c.close()
    # Verify the MAIN DB *and* every sidecar.
    for probe in glob.glob(f + "*"):
        hit = subprocess.run(["grep","-caF",tok,probe],capture_output=True,text=True).stdout.strip()
        if hit not in ("0",""):
            dirty.append(probe)
            print(f"  STILL PRESENT: {probe}")
print("clean" if not dirty else f"{len(dirty)} file(s) still hold the token")
sys.exit(1 if dirty else 0)
EOF
```

Scrubbing is point-in-time: the sink re-captures on the next MCP refresh. It is
what you do after rotating a credential, not a control that keeps the buffer clean.

### Alert rules (configured in Sentry, not in this repo)

Do **not** poll the Sentry API at high frequency. Sentry's own guidance is
*"Polling the API for updates will likely trigger rate limiting quickly;
webhooks are recommended instead."* Detection latency is also not the
bottleneck here - `CORE-BACKEND-K9` sat unresolved from 2025-03-19 with 1404
events. The bottleneck is that nobody triages.

**One bounded exception exists, and this paragraph was amended to admit it**
(`scripts/sentry-issue-watchdog.sh`, added 2026-08-25). It polls three projects
once every 30 minutes: **3 requests / 30 min = 144/day**, against a *measured*
limit of `x-sentry-rate-limit-limit: 5` over a ~1s window - i.e. a burst limit,
which sequential half-hourly requests never approach. It also handles 429
explicitly. If you are adding a second poller, do this arithmetic again rather
than citing this exception; two of these is a different question from one.

The reasoning above still governs the design: because latency is not the
bottleneck, the cadence stays slow, and the watchdog exists to close the
**triage** gap (nobody looks at these), not the **detection** gap.

Measured while writing it: `statsPeriod` accepts only `''`, `24h` and `14d` -
`7d` is rejected with `{"detail":"Invalid stats_period..."}`, so the watchdog
pulls `14d` and filters `firstSeen` locally.

Configure two alert rules over `core-backend`, `credits-web-next` and
`muso-auth` (never `flutter` - it ships through App Store review, so there is no
same-day fix to deploy):

| Rule | Condition | Delivers to |
|---|---|---|
| `sentry-p0` | new or regressed issue, rising user impact, or a culprit on an auth/payment/subscription path | the paging channel |
| `sentry-triage` | any new issue in the three projects | the triage channel |

Route both through Sentry's native Slack integration. Two things about the
destination channel are load-bearing and easy to get wrong:

**A posted alert does NOT summon the agent.** `cto`'s binding for `#prod-alerts`
(`C0BA8QMV3ME`) is `{"enabled": true, "requireMention": true, "allowBots": true}`
in `openclaw-main.json`. `allowBots` lets a Sentry message through, but
`requireMention` means the agent only wakes on a literal `<@U...>` mention in the
message body. A Sentry alert rule that posts without one produces a clean-looking
channel full of alerts and **zero** agent turns: a silent no-op that reads as a
working integration. To auto-summon, put the mention in the Sentry Slack action's
notes field.

**Think before you add that mention.** DevOps deliberately STOPPED auto-summoning
`cto` on prod alerts on 2026-07-21 (PR #723, "reduce codex token burn") - see
`workspaces/cto/SOUL.md`, which now reads "when a human tags you". Adding the
mention to a Sentry rule re-creates exactly the cost regression that PR removed,
on a second alert stream. The conservative default is to post WITHOUT a mention
and let a human pull `cto` in on the alerts that matter; only add the mention if
you have decided the token cost is worth it, and say so here when you do.

**Mind which skill a `#prod-alerts` mention summons.** `workspaces/cto/SOUL.md`
binds that channel to `cto-prod-alert-triage` (the prod-LOG alert skill). A
Sentry alert landing there summons that skill, not `sentry-issue-triage` - which
is the one with the classification taxonomy, the P0 rule, and the project map.
Either use a dedicated Sentry channel (and bind `cto` to it), or update SOUL.md
to route Sentry-sourced threads to `sentry-issue-triage`.

**Do not key severity on Sentry's `issue.priority:high`.** Measured 2026-08-21,
fourteen of the fifteen org-wide high-priority issues were Flutter client-side
network noise (socket closed, request timeouts, TLS handshake failures, CDN
aborts, DNS failures). The usable P0 rule is the three-part one in the
`sentry-issue-triage` skill.

### The issue watchdog

`scripts/sentry-issue-watchdog.sh`, installed by `install-aux-units.sh` as
`/etc/cron.d/sentry-issue-watchdog`, `*/30`, logging to
`/var/log/sentry-issue-watchdog.log`. It polls the three code-owning projects,
posts one digest to **#sentry-alerts (`C0BSVKNU96V`)**, and - **only when
explicitly enabled** - wakes `cto` on exactly one candidate.

The channel id is a **constant in the script**, not a cron env var: the cron
file is regenerated wholesale on every deploy, so a channel that lived only
there would vanish on the next one and every tick would exit 2.

**Dispatch is OFF by default.** `SENTRY_WATCHDOG_DISPATCH` defaults to `0` in
the script, which is the single place the default lives. Turning autonomy on is
therefore a one-line reviewable diff, and reverting it is the same.

**Levers, in the order you should reach for them.** All are FILES. Do not put
env vars in the cron file - `install-aux-units.sh` regenerates it wholesale on
every deploy, so a knob added there disappears the moment a fix-forward ships,
which is precisely mid-incident.

| Lever | Effect |
|---|---|
| `touch /etc/hydra/sentry-issue-watchdog.no-dispatch` | keeps polling and digesting, wakes nobody |
| `touch /etc/hydra/sentry-issue-watchdog.disabled` | exits 0 before any network call |
| `rm /etc/cron.d/sentry-issue-watchdog` | **not durable** - regenerated by the next deploy |

**Reading a digest.** A healthy tick says `N new issue(s) in 3/3 projects`, or
posts nothing at all when there is nothing new. A tick that could not read
everything says `PARTIAL COVERAGE: queried 2/3 projects (muso-auth: http_500)`
and exits non-zero. **It will never say "no new issues" when it failed to
query** - that distinction is the whole point of the script and is pinned by
`scripts/tests/sentry-issue-watchdog.bats`. If you see partial coverage
repeatedly, the credential or the API is the problem, not the filter.

**Blindness pages itself.** Three consecutive all-fail ticks, a 401/403, or no
full-coverage poll in 24h each page `#clio_devops`. A 401 pages immediately
without waiting for the streak, because a dead credential is not a transient.

**Token.** Resolved in order: `$SENTRY_API_TOKEN`, then
`/opt/hydra/secrets/sentry.env` (mode 0600 enforced; refused if looser), then
the live `mcp.servers.sentry` header in `openclaw-main.json`. Note the prefix
differs between them: the MCP entry stores `Sentry-Bearer <tok>`, the REST API
needs `Bearer <tok>`. If you rotate one and not the other, the watchdog 401s
while the agent's MCP keeps working, or vice versa - the auth page is what tells
you.

**Dry run:** `SENTRY_WATCHDOG_SKIP_HOST_GUARD=1 SENTRY_WATCHDOG_STATE_DIR=/tmp/wd \
  scripts/sentry-issue-watchdog.sh --dry-run` prints the digest and the dispatch
it *would* make, touching no state and posting nothing.

**Tuning noise:** `skills-all/sentry-issue-triage/config/watchdog-exclude-patterns.txt`
(ERE, one per line, matched against `title | culprit | metadata.type`). A
pattern that does not compile **stops the run** rather than silently disabling
the exclusion. Edit it here and deploy; editing it on node-8 is overwritten by
the next rsync, silently.

### Turning it off

- Alerts only: disable the rules in Sentry.
- The watchdog: `touch /etc/hydra/sentry-issue-watchdog.disabled` (above).
- Everything: `openclaw --profile main mcp unset "sentry"` (`remove` is not a
  subcommand), or - while `plugins.installs` is still present and `mcp unset`
  refuses - the same jq + announce + atomic-rename path as registration, with
  `del(.mcp.servers.sentry)`. That entry is the only place the token lives, so
  removing it removes the credential; revoke it in Sentry too. The skill
  degrades to read-only doctrine with no tools behind it; nothing else depends
  on it.

### Known noise

Roughly eighty percent of org-wide event volume is the Flutter app's
`error_reporting_service.dart in ErrorReportingService.recordError` recording
ordinary transient network failures as errors: socket closed (1024 events),
request timeouts (810), CDN connection aborts (554), TLS handshake failures
(175), Knock DNS lookup failures (161). Filtering transient network exceptions
at the reporting call site would cut org-wide noise sharply and make every
downstream signal, including the P0 rule, far more reliable. That is a mobile
change, not a backend one.

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
