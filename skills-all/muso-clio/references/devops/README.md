# DevOps & Infrastructure

Terraform infrastructure and CI/CD for Muso.AI.

Source: [DevOps Knowledge Transfer (Notion)](https://www.notion.so/DevOps-Knowledge-Transfer-1df0f087197f4669a0aaa8026ffc13cd)

## Overview

| Attribute | Value |
|-----------|-------|
| **Repo** | `devops` |
| **IaC** | Terraform 1.5+ |
| **CI/CD** | Jenkins on ECS |
| **Cloud** | AWS (ECS, EKS, RDS, etc.) |
| **Registry** | AWS ECR |

## When to Load

Load this reference when:
- Creating or modifying Terraform resources
- Working with Jenkins pipelines
- Managing ECS or EKS deployments
- Configuring networking or security groups
- Setting up new environments

## Infrastructure Repositories

| Repo | Purpose |
|------|---------|
| [devops](https://github.com/Muso-AI/devops) | Main Terraform configurations |
| [terraform-modules](https://github.com/Muso-AI?q=terraform-module) | Reusable Terraform modules |
| [jenkins-shared-library](https://github.com/Muso-AI/jenkins-shared-library) | Reusable Jenkins pipeline steps |
| [docker-ci-tools](https://github.com/Muso-AI/docker-ci-tools) | CI/CD Docker image |

## Environment Structure

| Environment | Purpose | Terraform Path |
|-------------|---------|----------------|
| `global` | Shared resources (ECR, Route53) | `terraform/envs/global/` |
| `system` | CI/CD (Jenkins) | `terraform/envs/system/` |
| `dev` | Development | `terraform/envs/dev/` |
| `prod` | Production | `terraform/envs/prod/` |

## Terraform Folder Structure

```
terraform/
├── envs/
│   ├── global/     # ECR, Route53
│   ├── system/     # Jenkins infrastructure
│   ├── dev/        # Dev environment
│   └── prod/       # Prod environment
└── common/         # Shared code (symlinked)
    ├── network/    # VPC, subnets, security groups
    ├── data/       # Databases, S3, MongoDB Atlas
    ├── compute/    # ECS/EKS clusters, bastions
    └── app/        # Service definitions
```

## Infrastructure Components

### Compute
- **ECS on EC2**: Core services (API, workers, frontend)
- **EKS**: Data processing, analytics workers

### Networking
- VPC with public/private/database subnets
- NAT Gateways for private subnet internet
- VPC Peering to MongoDB Atlas
- VPC Endpoints (S3, SQS, SSM)
- Bastion hosts for internal access

### Data
- RDS PostgreSQL (core, analytics, stats)
- MongoDB Atlas (catalog, raw data)
- ElastiCache Redis
- S3 buckets (assets, data lake, logs)
- SQS queues

### Security
- WAF on CloudFront
- Security groups between tiers
- IAM roles (ECS task roles, EKS IRSA)
- Secrets Manager / SSM Parameter Store
- KMS for encryption at rest

## ECS Services (Growth Cluster)

| Service | Purpose |
|---------|---------|
| `core-backend-api` | Main API |
| `ai-chat-api` | AI chat |
| `core-worker` | Background jobs |
| `website` | Next.js website |
| `credits` | Nuxt.js credits app |
| `core-posters` | Poster generation |
| `render-service` | Media rendering |

## EKS Workloads (Catalog Cluster)

| Workload | Namespace | Purpose |
|----------|-----------|---------|
| Analytics Controller | `analytics` | Orchestration |
| Analytics Worker | `analytics` | Stats capture |
| Industry API | `industry-proc` | Catalog API |
| Industry Workers | `industry-proc` | Catalog processing |
| Feed Service | `feed-service` | Activity feeds |

## Key Terraform Files

| File | Purpose |
|------|---------|
| `compute/eks.tf` | EKS cluster |
| `compute/eks_tools.tf` | K8s tools (KEDA, autoscaler) |
| `compute/ecs.tf` | ECS cluster |
| `compute/ec2_bastion.tf` | Bastion host |
| `data/mongodb_*.tf` | MongoDB Atlas |
| `app/svc_*.tf` | Service definitions |

## Secrets Location

| Type | Location |
|------|----------|
| Shared credentials | `keybase://team/musical.infra` |
| Infrastructure secrets | SSM `/infra/*` |
| App secrets | SSM `/app/{service}/{env}/` |
| RDS/Mongo credentials | AWS Secrets Manager |

## Backup Policies

| Service | Retention |
|---------|-----------|
| MongoDB Atlas | 7 daily backups + PIT |
| RDS PostgreSQL | 21 days |
| ElastiCache Redis | 7 days |
| Jenkins EFS | AWS Backup |

## CloudWatch Dashboards

| Dashboard | Purpose |
|-----------|---------|
| `core-backend-sqs-prod` | SQS queues |
| `core-backend-api-prod` | API, ECS, RDS, Redis |
| `industry-data-processing-prod` | Industry workers |
| `data-capture` | Capture services |
| `analytics` | Analytics capture |

## Related References

The `muso-devops` skill that this section used to point at was removed as dead
weight; it was never bound to the devops agent and its EKS/ECS content described
AWS infrastructure decommissioned on 2026-05-31. For current infrastructure see
`docs/lessons/infrastructure-topology.md` (all-OVH topology) and consult H-DevOps
before touching infra.
