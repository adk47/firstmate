# TOOLS.md -- DevOps Agent

## AWS CLI
- **Region policy**: us-west-2 ONLY. Never operate in any other region.
- Read access for monitoring and data dumps
- **NEVER modify AWS without Aaron's explicit permission**
- Use for: CloudWatch metrics, CloudTrail audit, EKS monitoring (legacy), S3 data access

## kubectl
- Read operations: always allowed
- Write operations: require explicit approval from Aaron or Artem D
- Cluster context: OVH K3s (7-node, 3 server + 4 agent)
- Key namespaces: default, data-processing, monitoring, vault, longhorn-system

## Prod Logs (skill: muso-devops-prod-logs)
- **Prod log fetches go through `scripts/fetch-prod-logs.sh`** (skill
  `muso-devops-prod-logs`) — don't improvise `kubectl logs | grep` pipelines.
  The wrapper guarantees read-only verbs, per-pod coverage of multi-replica
  deployments (`kubectl logs deploy/X` samples ONE pod), secret redaction, and
  bounded Slack-safe output. See the skill's SKILL.md for flags and the
  ask→command mapping.
- Automatic prod error alerts already flow to #prod-alerts (C0BA8QMV3ME) via
  `scripts/prod-log-alert-watchdog.sh` (system cron, every 5 min) — if someone
  reports a prod error, check that channel's recent posts before re-deriving.
- **After each alert posts, the watchdog wakes you to triage it** (message
  starts `PROD-ALERT TRIAGE`). Run the `muso-devops-alert-triage` skill: it
  classifies severity (P0/P1/P2+), posts ONE threaded reply explaining the
  error, tags Nick + Aaron and summons the CTO on P0/P1. Rubric + reply format
  live in that skill's SKILL.md.

## Env Vars (skill: muso-devops-set-env)
- **The ONLY sanctioned path is `scripts/devops-set-env.sh`** — never set an env
  var by calling `kubectl`/`vault` directly. The wrapper enforces, in bash below you:
  a secret-shaped **blocklist** (`config/protected-env-keys.txt`), a **target allowlist**,
  an authorized-requester gate, a **window rate-cap**, and **fail-closed audit**
  (captures the prior value for rollback). `--env` selects the rule-set (defaults to `prod`).
- **PROD (`--env prod`, default)**: non-secret config (LOG_LEVEL, feature flags,
  timeouts, rate limits) on an allow-listed target (`config/target-allowlist.txt`),
  requested by an authorized human (`config/envset-requesters.txt`), goes through without
  a second approval. **Secret-shaped keys are refused** and route to a green-light approver
  (`config/blocklist-override-approvers.txt` — Nick/Aaron).
- **DEV (`--env dev`)**: for Serhii/Artem D (`config/dev-envset-requesters.txt`) a dev env
  var — **secret-shaped included — is self-serve, no green-light** (Nick's directive).
  Targets glob-match `config/dev-target-allowlist.txt` (`muso-dev/*`); secret VALUES are
  still redacted in the audit and the write is contained to the `muso-dev` scope.
- **Never bypass the wrapper.** The blocklist is only safe because it's enforced under
  you; real containment is a scoped Vault/K8s credential (provisioned by Artem/Aaron).
- **Status**: the real write backend is fail-closed (prod AND dev) until Phase-0 pins the
  write command and the credential exists — runs in dry-run/stub until then. See the
  skill's SKILL.md.

## SSH
- SSH key: `~/.ssh/ovh_muso`
- Access to all 7 OVH nodes (ovh-node-1 through ovh-node-7)
- Node-7 SSH: user `ubuntu`, password auth available
- SSH tunneling for internal services (Grafana, MinIO, Airflow, Trino)

## Monitoring Stack
- **Prometheus**: metrics collection and alerting
- **Grafana**: dashboards and visualization (VPN-only access)
- **Loki**: log aggregation
- **Longhorn alerts**: storage health monitoring
- Alert interpretation: correlate Prometheus alerts with Grafana dashboards for context

## Vault
- HashiCorp Vault with AppRole authentication
- Secret management for all services
- Backup: vault-backup-offsite CronJob
- **NEVER expose Vault tokens or secrets in any channel**

## KEDA Autoscaling
- Queue-based autoscaling for analytics workers
- Monitor: queue depth, scaling events, resource utilization
- Configuration in k8s/prod/workers/

## Webshare Proxy
- Proxy service for external API calls
- Monitor: proxy health, rotation schedule, usage limits
- **GitHub key leak scan**: regular scanning for exposed credentials

## CI/CD Pipeline
- Cron-based sync pipeline on ovh-node-1 (every 4h)
- Script: `/opt/muso-sync/ovh-sync-pipeline.sh`
- Commands: `--status`, `--force-all`, `--force <service>`, `--dags-only`
- Logs: `/var/log/muso-sync/`

## Slack
- Bound channels: #devops, #deploys, #infra-alerts
- Alert routing: infrastructure alerts go to #infra-alerts, deployment status to #deploys

## Infra Pulse Rule
- **NEVER post recurring monitoring updates to shared channels more than 1x/day**
- Routine health checks go to #infra-alerts only
- Only escalate to #exec or DM Aaron for genuine incidents
