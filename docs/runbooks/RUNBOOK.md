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
5. [Emergency Procedures](#emergency-procedures)

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

- **Deploy fails at Step 0 (drift check)** — the server has files the repo doesn't. See briefing in deploy log for the list. Use `scripts/sync-from-server.sh` to pull server-side edits into the repo first, commit, then retry the deploy.
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
prod incident or a sales lead): `prod-log-alert-watchdog`, `ads-inquiry-watchdog`,
`merge-landing-watchdog`, `stale-ticket-watchdog`, and the systemic
`intercom-data-complaint-watchdog`. This split is enforced: any new
`*-watchdog.{sh,py}` that is neither guarded nor listed in
`scripts/tests/fixtures/maintenance-guard-exempt.txt` fails CI
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

**Auto-recovery (default)**: `codex-keepalive.sh` (15-min cron) has TWO
triggers for `scripts/lib/codex-account-rotate.sh --auto`:
- **Proactive** (preferred): a fresh rate_limits snapshot showing any quota
  window ≥95% used (`CODEX_KEEPALIVE_ROTATE_AT`) with its reset >60 min away —
  rotates BEFORE the cap error ever fires, skipping the degraded window.
- **Reactive** (backstop): the cap signature in the journal.

The rotation writes the active-account state file
(`/var/lib/hydra/codex-active-account`, deploy-proof: outside the rsync tree,
re-resolved by `codex-auth-sync.sh` on every heal), **archives the outgoing
account's freshest quota snapshot** to `/var/lib/hydra/codex-usage/` (rollouts
are account-blind on 7.x — the archive is the only per-account quota
knowledge; `resets_at` is absolute so it stays meaningful), re-syncs all
runtime stores, drain-restarts both gateways, pages #clio_devops.

Guards: 120-min cooldown (rc 3); target-viability — `--auto` refuses (rc 7) a
standby whose ARCHIVED snapshot is still capped, and skips candidates whose
token is missing/expired (rc 4). On rc 3/7 with the signature live, BOTH
subscriptions are spent: the keepalive pages that honestly (with the earliest
known reset ETA) and the fleet rides the OpenRouter rung (the model chain's
job) until a window resets.

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
