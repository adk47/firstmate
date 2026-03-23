---
name: muso-devops
description: |
  Muso.AI DevOps and infrastructure expert. Terraform, EKS/ECS, CI/CD
  pipelines, and operational procedures.
  Triggers: "devops", "terraform", "deploy", "infrastructure", "ci/cd"
compatibility: |
  Optional: AWS CLI configured for Muso accounts/profiles. Some workflows assume Terraform familiarity.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# muso-devops

Muso.AI DevOps and infrastructure expert. Provides knowledge of deployment, CI/CD, infrastructure management, and operational procedures.

Source: [DevOps Knowledge Transfer (Notion)](https://www.notion.so/DevOps-Knowledge-Transfer-1df0f087197f4669a0aaa8026ffc13cd)

## AWS CLI Profiles

| Profile | Account | Resources | Region |
|---------|---------|-----------|--------|
| `muso-flagship-readonly` | Flagship | Athena, Glue (91 DBs), Route53, Lambda, ECS, EKS | us-west-2 |
| `muso-readonly` | Plaque | S3 buckets | us-west-2 |

### CRITICAL: Region Policy

**All Muso resources (dev AND prod) are in `us-west-2`. Do NOT search other regions.**

- Both dev (`*-dev`) and prod (`*-prod`) environments are in us-west-2
- If a query returns empty results in us-west-2, report "no resources found" — do not automatically search other regions
- Resources in other regions (eu-west-1, us-east-1, etc.) are abandoned staging/test artifacts from 2022 or earlier
- Only search other regions if the user explicitly requests it

```bash
# Athena/Glue (Flagship)
aws athena list-named-queries --profile muso-flagship-readonly --region us-west-2
aws glue get-databases --profile muso-flagship-readonly --region us-west-2

# Lambda (Flagship) - us-west-2 ONLY
aws lambda list-functions --profile muso-flagship-readonly --region us-west-2

# S3 (Plaque)
aws s3 ls --profile muso-readonly --region us-west-2
```

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
