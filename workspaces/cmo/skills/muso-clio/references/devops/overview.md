# DevOps & Infrastructure

**Repo:** `devops`

## Infrastructure (Terraform IaC)

### Tools & Versions
- **Terraform**: v1.5.7+
- **Provider**: AWS (`hashicorp/aws`)
- **State Backend**: S3 (`muso-ai-tf-state`) with DynamoDB locking

### Architecture Pattern

**DRY via Symlinks**: Common configurations in `/terraform/common/` are symlinked into environment directories.

**Layered Infrastructure**: Each environment has 4 layers applied in order:
1. `network` - VPC, subnets, security groups
2. `data` - Databases, caches
3. `compute` - ECS/EKS clusters, ALBs, bastion hosts
4. `app` - Services, API Gateway, CloudFront, DNS

### Directory Structure

```
terraform/
├── common/                 # Shared configs (symlinked)
│   ├── network/
│   ├── data/
│   ├── compute/
│   └── app/
├── envs/
│   ├── global/            # Shared resources (ECR, Route53, IAM)
│   │   ├── iam/
│   │   ├── route53/
│   │   ├── ecr/
│   │   ├── s3/
│   │   └── dynamodb/
│   ├── system/            # CI/CD (Jenkins)
│   │   ├── network/
│   │   ├── compute/
│   │   └── app/
│   ├── dev/               # Development
│   │   ├── network/
│   │   ├── data/
│   │   ├── compute/
│   │   └── app/
│   └── prod/              # Production
│       ├── network/
│       ├── data/
│       ├── compute/
│       └── app/
└── modules/               # Custom modules
```

### File Naming Conventions
- Service files: `svc_<service>_<resource>.tf` (e.g., `svc_analytics_k8s.tf`)
- Standard files: `locals.tf`, `variables.tf`, `outputs.tf`, `data.tf`

### State Management
- State key pattern: `<env>/us-west-2/<layer>.tfstate`
- Cross-layer references via `terraform_remote_state`

## Deployment Topology

```text
AWS Account (per environment)
  VPC
    Public subnets (multi-AZ)
      - NAT gateway(s)
      - Public ALB
      - Bastion host

    Private subnets (multi-AZ)
      ECS Cluster (EC2 ASGs)
        - ecs-core-common   (Core API, AI Chat, Workers)
        - ecs-core-frontend (Website, Credits)
        - ecs-core-workers  (Posters, Render, Encore)

      EKS Cluster (node groups)
        - system
        - application
        - industry-proc

      - Internal ALB

    DB subnets (multi-AZ)
      - RDS Postgres (Core Backend)
      - RDS Postgres (Analytics)
      - ElastiCache Redis

External (SaaS)
  MongoDB Atlas (VPC peered)

VPC <-> (VPC peering) <-> MongoDB Atlas
```

## CI/CD Pipeline

**Primary Tool:** Jenkins (self-hosted on ECS)

```text
Source control
  GitHub repos (app code)
  devops repo (Terraform)
    -> webhook -> Jenkins (ECS + EFS)

Jenkins
  - docker build & push -> AWS ECR
  - terraform plan/apply -> Terraform Apply

Deploy
  ECR image -> ECS service update
  ECR image -> EKS deploy (kubectl / Helm)
```

### Jenkins Setup
- Runs as ECS service with EFS-backed persistent storage
- Uses Jenkins Shared Library from `jenkins-shared-library` repo
- Docker images: `docker-ci-tools` repo
- ECR: `068358774785.dkr.ecr.us-west-2.amazonaws.com`

### Pipeline Patterns
- Declarative pipelines with `@Library('global@main')`
- ECR login via `ecrLogin()` helper
- Version tagging from `.version` file

## Environments

| Environment | Purpose | Terraform Path |
|-------------|---------|----------------|
| `global` | Shared resources (ECR, Route53, IAM) | `terraform/envs/global/` |
| `system` | CI/CD (Jenkins) | `terraform/envs/system/` |
| `dev` | Development workloads | `terraform/envs/dev/` |
| `prod` | Production workloads | `terraform/envs/prod/` |

**Apply Order:** `global` -> `system` -> `dev` (network->data->compute->app) -> `prod`

## ECS Services

| Service | ASG | Purpose |
|---------|-----|---------|
| `core-backend-api` | common | Main API |
| `ai-chat-api` | common | AI chat endpoints |
| `core-worker` | common | Background jobs |
| `website` | frontend | Next.js website |
| `credits` | frontend | Nuxt.js credits app |
| `core-posters` | workers | Poster generation |
| `render-service` | workers | Media rendering |
| `encore` | workers | Encore service |
| `core-migrations` | - | DB migrations |

## EKS Workloads

| Workload | Namespace | Purpose |
|----------|-----------|---------|
| Analytics Controller | `analytics` | Orchestrates analytics jobs |
| Analytics Worker | `analytics` | Executes analytics tasks |
| Analytics Scheduler | `analytics` | Cron-based scheduling |
| Feed Service | `feed-service` | Feed generation/serving |
| Industry Processing | `industry-proc` | Industry data processing |

### EKS Cluster Tools (Helm)
- AWS Node Termination Handler
- Metrics Server
- Cluster Autoscaler
- AWS Load Balancer Controller
- AWS FluentBit (logging)
- AWS CloudWatch Metrics Agent
- KEDA (event-driven autoscaling)

### IRSA Pattern (IAM Roles for Service Accounts)
```hcl
annotations = {
  "eks.amazonaws.com/role-arn" = aws_iam_role.sa_<service>.arn
}
```

## Monitoring & Logging

### CloudWatch
- **Dashboards**: Terraform-managed (e.g., `TF-feed-service-<env>`)
- **Alarms**: HTTP error rates (4xx/5xx), response times, unhealthy targets
- **Log Groups**: Per-service ECS/EKS logs
- **Container Insights**: Configurable per ECS cluster

### Metrics Collection
- FluentBit for EKS pod logs -> CloudWatch Logs
- CloudWatch Agent for container insights
- ALB metrics for HTTP status codes

## Terraform Modules Used

| Module | Version | Purpose |
|--------|---------|---------|
| `terraform-aws-modules/eks/aws` | ~> 20.0 | EKS cluster |
| `terraform-aws-modules/ecs/aws` | ~> 5.7 | ECS cluster |
| `terraform-aws-modules/rds/aws` | ~> 6.4 | RDS instances |
| `terraform-aws-modules/autoscaling/aws` | ~> 7.3 | ASG management |
| `terraform-aws-modules/iam/aws` | ~> 5.30 | IAM roles/policies |

## Key Operations

### Adding New Terraform Files
1. Add to `/terraform/common/<layer>/`
2. Create symlinks in both `envs/dev/<layer>/` and `envs/prod/<layer>/`

```bash
cd terraform/envs/dev/app && ln -s ../../../common/app/new_file.tf new_file.tf
cd terraform/envs/prod/app && ln -s ../../../common/app/new_file.tf new_file.tf
```

### Common Tags Pattern
```hcl
tags = merge({ Name = "<resource-name>" }, local.common_tags)
# local.common_tags = { Project, Env, Managed="terraform", Owner="infra" }
```

### Instance Refresh
After AMI/version changes:
```bash
aws autoscaling start-instance-refresh --auto-scaling-group-name <asg-name> ...
```
