---
name: muso-devops
description: |
  Muso.AI DevOps and infrastructure expert. Terraform, EKS/ECS, CI/CD
  pipelines, and operational procedures.
  Triggers: "devops", "terraform", "deploy", "infrastructure", "ci/cd"
compatibility: |
  Some workflows assume Terraform familiarity. Warehouse SQL runs on OVH Trino
  via `muso query`.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# muso-devops

Muso.AI DevOps and infrastructure expert. Provides knowledge of deployment, CI/CD, infrastructure management, and operational procedures.

Source: [DevOps Knowledge Transfer (Notion)](https://www.notion.so/DevOps-Knowledge-Transfer-1df0f087197f4669a0aaa8026ffc13cd)

## ⚠️ AWS is decommissioned (2026-05-31) — historical content only

**There is no AWS account to operate.** All infrastructure is OVH (K3s cluster,
Trino warehouse, OVH S3 data lake). The AWS-era material in this skill and in
[reference.md](./reference.md) (EKS/ECS, CloudWatch, Lambda, Glue, us-west-2
region policy, AWS CLI profiles) is a knowledge-transfer ARCHIVE — read it for
historical context, never as an instruction to run anything against AWS.

Live equivalents:
- Warehouse SQL: `muso query "<SQL>"` (skill `muso-query-writer`)
- Infra topology + ground truth: `docs/lessons/infrastructure-topology.md`
- Production infra changes are GitOps-managed by H-DevOps — consult them before touching infra

## When to Use

- Infrastructure management (Terraform, EKS, ECS)
- CI/CD pipelines (Jenkins, GitHub Actions)
- Deployment procedures and runbooks
- Database access and tunneling
- Monitoring and alerting
- Mobile CI/CD (Android/iOS with Fastlane)
- Secrets management (Keybase, SSM, Secrets Manager)
- Auto-scaling configuration (KEDA, ECS Capacity Provider)

## Triggers

- "devops", "infrastructure", "terraform"
- "jenkins", "ci/cd", "deployment"
- "eks", "ecs", "kubernetes", "docker"
- "tunnel", "ssh", "database access"
- "monitoring", "alerting", "cloudwatch"
- "keda", "autoscaling", "scaling"
- "fastlane", "mobile build", "ios build", "android build"
- "secrets", "ssm", "keybase"
- "bastion", "vpc", "networking"

## Reference Contents

See [reference.md](./reference.md) for complete documentation including:

### Infrastructure
- Infrastructure repositories (devops, terraform-modules, jenkins-shared-library)
- Terraform folder structure and key files
- Environment configurations (dev, prod, system, global)

### Compute
- EKS deployments (Helm charts, IRSA, node groups, aws-auth)
- ECS deployments (task definitions, capacity providers)
- Auto-scaling (KEDA, ECS Capacity Provider, Cluster Autoscaler)
- Bastion hosts for VPC access

### Data & Secrets
- MongoDB Atlas configuration
- PostgreSQL roles management
- Secrets management (Keybase, SSM, Secrets Manager)
- Backup policies and retention periods

### CI/CD
- Jenkins infrastructure and configuration
- Jenkins shared library functions
- GitHub Branch Source Plugin setup
- Credential management via AWS Secrets Manager

### Mobile
- Android builds (EC2 agent, Google Play release)
- iOS builds (Macincloud agent, TestFlight release)
- Fastlane automation
- Signing certificates and provisioning

### Monitoring
- CloudWatch dashboards (6 key dashboards)
- CloudWatch alarm naming patterns
- Alerting configuration

## Known Gaps

- Terraform lacks CI/CD automation for Airflow deployment
- CloudWatch alarms/dashboards managed manually (IaC planned)
- Jenkins plugins managed manually (JCasC planned)
- IAM users managed manually (SSO migration planned)
- EKS users all have system:masters (RBAC improvement needed)
