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
