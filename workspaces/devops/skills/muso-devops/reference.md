# Muso DevOps Reference

This skill covers infrastructure management, deployment processes, monitoring, and operational procedures for the Muso.AI platform. Use this reference when deploying services, managing infrastructure, troubleshooting operational issues, or understanding the CI/CD pipeline.

Source: [DevOps Knowledge Transfer (Notion)](https://www.notion.so/DevOps-Knowledge-Transfer-1df0f087197f4669a0aaa8026ffc13cd)

---

## Infrastructure Repositories

| Name | Description | GitHub |
|------|-------------|--------|
| **devops** | Main infrastructure repository with Terraform configurations | [Muso-AI/devops](https://github.com/Muso-AI/devops) |
| **terraform-modules** | Reusable Terraform modules for system resources | [Search: terraform-module](https://github.com/Muso-AI?q=terraform-module&type=all) |
| **jenkins-shared-library** | Reusable Jenkins declarative pipeline steps | [Muso-AI/jenkins-shared-library](https://github.com/Muso-AI/jenkins-shared-library) |
| **docker-ci-tools** | Docker image with CI/CD tools (kubectl, helm, AWS CLI) | [Muso-AI/docker-ci-tools](https://github.com/Muso-AI/docker-ci-tools) |

All infrastructure repositories are marked with the [`infra`](https://github.com/Muso-AI?q=infra&type=all) GitHub label.

---

## Key Concepts

**Infrastructure Environments**: Muso maintains separate `dev` and `prod` environments with distinct suffixes (`-dev`, `-prod`).

**Cluster Architecture**:
- **Growth (ECS)**: User-facing services (Core Backend API, Credits Frontend, Render Service)
- **Catalog/Platform (EKS)**: Data processing services (Industry Processing, Analytics Workers, Capture)

**Terraform Management**: Infrastructure as Code for almost all AWS resources. Exceptions: Platform management (MWAA), manual CloudWatch alarms, WAF rules.

**Jenkins CI/CD**: Continuous integration/deployment using Jenkinsfiles in each repository.

**KEDA**: Kubernetes Event-Driven Autoscaling for worker queue scaling based on SQS metrics.

**Bastion Host**: SSH gateway for accessing databases within the VPC.

---

## GitHub Access Management

- Access managed through **teams**, not individual permissions
- [`devops` team](https://github.com/orgs/Muso-AI/teams/devops) has **Admin** access to all repositories
- Other teams have **Maintain** or **Write** access based on project ownership
- [`muso-ci`](https://github.com/muso-ci) is the GitHub bot user for Jenkins and ClickUp integration

**Teams**:
- Backend
- DataEngineering
- DevOps (Admin access)
- Frontend
- Mobile

**Repository Settings**:
- Naming: lowercase with dash delimiter (e.g., `core-backend`)
- Branch protection rules for `main`, `develop`
- Require status checks to pass before merging
- Automatically delete head branches

---

## Terraform Structure

Infrastructure managed via Terraform following [Application Infrastructure Layers](https://www.notion.so/Application-Infrastructure-Layers-bd21411d005546619248368d55ee2dfb) principle.

### Environment Structure

```
terraform/
├── envs/
│   ├── global/     # Shared resources (ECR, Route53)
│   ├── system/     # CI/CD (Jenkins)
│   ├── dev/        # Development environment
│   └── prod/       # Production environment
└── common/         # Shared code (symlinked to envs)
    ├── network/    # VPC, subnets, security groups
    ├── data/       # Databases, S3 buckets, data stores
    ├── compute/    # ECS/EKS clusters, EC2 instances
    └── app/        # Service definitions (most frequently modified)
```

### Key Terraform Files

| File | Purpose |
|------|---------|
| `terraform/common/data/` | MongoDB Atlas, RDS, S3 configuration |
| `terraform/common/data/mongodb_peering.tf` | AWS peering between Atlas and VPCs |
| `terraform/common/data/mongodb_users.tf` | MongoDB user management |
| `terraform/common/compute/eks.tf` | EKS cluster configuration |
| `terraform/common/compute/eks_tools.tf` | Kubernetes system tools |
| `terraform/common/compute/ecs.tf` | ECS cluster configuration |
| `terraform/common/compute/ecs_tools.tf` | ECS utilities |
| `terraform/common/compute/ec2_bastion.tf` | Bastion host configuration |
| `terraform/common/compute/locals_eks.tf` | EKS node group definitions |
| `terraform/common/app/` | Service-specific configurations |

---

## MongoDB Atlas

**Terraform Path**: `terraform/common/data/`

**Configuration**:
- Cluster, IAM, S3 export, and backup policy managed via Terraform
- AWS peering: `terraform/common/data/mongodb_peering.tf`
- User management: `terraform/common/data/mongodb_users.tf`

**Access**:
- Via bastion host only
- Terraform provider uses [`mongodb-atlas-api-key`](https://us-west-2.console.aws.amazon.com/secretsmanager/secret?name=mongodb-atlas-api-key&region=us-west-2) AWS Secret

**Get MongoDB User Password**:
```bash
terraform output mongodb_product_api_db_users
```

---

## PostgreSQL Roles Management

**Approach**: Role-based access using PostgreSQL built-in mechanisms

**Configuration**:
- Master credentials stored in AWS Secrets Manager during instance creation
- Users/roles created following [PostgreSQL User Management Guide](https://github.com/Muso-AI/devops?tab=readme-ov-file#postgresql-user-management)
- Credentials generated by Terraform, also stored in Keybase
- Outputs: `terraform/common/app/outputs.tf#L73`

---

## Secrets Management

### Keybase
All shared credentials stored at: `keybase://team/musical.infra`
- API Keys/Tokens
- RDS/MongoDB Atlas users
- Mobile app signing certificates
- SSH keys

### AWS SSM Parameters

**Infrastructure parameters**: Prefix `/infra/`
- [View all](https://us-west-2.console.aws.amazon.com/systems-manager/parameters/?region=us-west-2&tab=Table#list_parameter_filters=Name:Contains:%2Finfra)

**Application parameters by service**:
- [/app/core-backend/prod/](https://us-west-2.console.aws.amazon.com/systems-manager/parameters/?region=us-west-2&tab=Table#list_parameter_filters=Name:Contains:%2Fapp%2Fcore-backend%2Fprod%2F)
- [/app/mobile/](https://us-west-2.console.aws.amazon.com/systems-manager/parameters/?region=us-west-2&tab=Table#list_parameter_filters=Name:Contains:%2Fapp%2Fmobile%2F)

> **Note**: SSM parameters in ECS task definitions are created with placeholder values by Terraform and must be replaced **manually**.
> File: `terraform/common/app/ssm.tf#L5`

### AWS Secrets Manager

| Secret | Purpose |
|--------|---------|
| [`mongodb-atlas-api-key`](https://us-west-2.console.aws.amazon.com/secretsmanager/secret?name=mongodb-atlas-api-key&region=us-west-2) | Terraform MongoDB Atlas provider |
| [`mobile-app-config-prod`](https://us-west-2.console.aws.amazon.com/secretsmanager/secret?name=mobile-app-config-prod&region=us-west-2) | Mobile app config (Jenkins credential via AWS Secrets provider) |
| [`jenkins-agents-ec2-ssh-key`](https://us-west-2.console.aws.amazon.com/secretsmanager/secret?name=jenkins-agents-ec2-ssh-key&region=us-west-2) | SSH key for Jenkins agents |
| `rds!db-*` | RDS master credentials (AWS managed) |

---

## EKS Deployments

**Clusters**: `core-dev`, `core-prod`

### Terraform Configuration

| File | Purpose |
|------|---------|
| `terraform/common/compute/eks.tf` | EKS cluster definition |
| `terraform/common/compute/eks_tools.tf` | System tools (KEDA, Cluster Autoscaler, etc.) |
| `terraform/common/compute/locals_eks.tf` | Node group definitions |

### Helm Charts

Each service repository contains its own Helm charts in `ops/helm/`.

**Example (industry-data-processing)**:
- Chart: `ops/helm/industry-data-processing/`
- Default values: `values.yaml`
- Prod overrides: `values-prod.yaml`

### Node Groups

Self-managed node groups with custom label `node.kubernetes.io/group`:
- Example: `node.kubernetes.io/group=industry-proc`
- Used as NodeSelector in deployments
- Config: `terraform/common/compute/locals_eks.tf#L120`

### IRSA (IAM Roles for Service Accounts)

AWS resource access via temporary credentials:
- Example: `terraform/common/app/svc_industry_proc_iam.tf`

### Application Config

Config injected via environment variables from Kubernetes secrets:
- Secret example: `industry-proc-config` in `industry-proc` namespace
- Terraform: `terraform/common/app/svc_industry_proc_k8s.tf#L37`
- Additional env vars: `ops/helm/industry-data-processing/values.yaml#L130`

### EKS Cluster Access

Access managed via `aws-auth` ConfigMap in `kube-system` namespace (**manually**):

```bash
kubectl get configmaps -n kube-system aws-auth -o yaml
```

Current users have `system:masters` RBAC group (needs improvement for least-privilege).

### AWS LB Ingress Controller

Exposes services via AWS ALB:
- Module: [terraform-module-aws-lb-controller](https://github.com/Muso-AI/terraform-module-aws-lb-controller)
- Example ingress: `ops/helm/industry-data-processing/templates/ingress-api.yaml`

---

## ECS Deployments

**Clusters**: `core-dev`, `core-prod`

### Terraform Configuration

| File | Purpose |
|------|---------|
| `terraform/common/compute/ecs.tf` | ECS cluster definition |
| `terraform/common/compute/ecs_tools.tf` | ECS utilities |
| `terraform/common/app/svc_core_api_ecs.tf` | Core Backend API service |
| `terraform/common/app/locals_ecs.tf` | ECS task definition locals |

### Application Config

Environment variables injected from:
- Plain definition in ECS task definition
- AWS SSM parameters (for external/secret values)

References:
- `terraform/common/app/svc_core_api_ecs.tf#L94` (env vars)
- `terraform/common/app/svc_core_api_ecs.tf#L115` (secrets)

### Deployment via Jenkins

Custom shared library functions:
- [ecsServiceDeploy.groovy](https://github.com/Muso-AI/jenkins-shared-library/blob/main/vars/ecsServiceDeploy.groovy)
- Pipeline example: [core-backend Jenkinsfile#L134](https://github.com/Muso-AI/core-backend/blob/develop/Jenkinsfile#L134)

---

## Auto-Scaling

### ECS Capacity Provider

AWS ECS Capacity Provider with managed scaling enabled:
- `terraform/common/compute/ecs.tf#L82`
- `terraform/common/compute/locals.tf#L29`

### EKS Cluster Autoscaler

[Cluster Autoscaler on AWS](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md) manages node pools via EC2 ASG.
- Module: [terraform-module-cluster-autoscaler](https://github.com/Muso-AI/terraform-module-cluster-autoscaler)

### KEDA

[KEDA](https://keda.sh/) for event-driven autoscaling based on SQS queue depth.

**Installation**: `terraform/common/compute/eks_tools.tf#L207`
- Module: [terraform-module-keda](https://github.com/Muso-AI/terraform-module-keda)

**Services using KEDA**:
- `industry-data-processing` workers
- `capture-import-controller` worker
- `capture-crawling` workers
- `analytics` workers

**ScaledObject Example**:
```yaml
# ops/helm/industry-data-processing/templates/scaledobject-workers.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: industry-worker
spec:
  scaleTargetRef:
    name: industry-worker
  minReplicaCount: 1
  maxReplicaCount: 50
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: https://sqs.us-west-2.amazonaws.com/068358774785/queue-name
        queueLength: "100"
        awsRegion: us-west-2
```

---

## AWS Internal Network Access

### Bastion Hosts

Used for accessing resources in private VPC subnets.

**Configuration**: `terraform/common/compute/ec2_bastion.tf`

**Shared SSH Key:**
- Location: AWS Secrets Manager (`jenkins-agents-ec2-ssh-key` or similar)
- Same key provides access to MongoDB, PostgreSQL/Aurora, and all internal VPC resources
- As of Jan 2026, the key hadn't been rotated in ~2 years

**Key Rotation Guidance:**
- Rotate when team members with access leave the company
- Rotate during annual security reviews
- Update in Secrets Manager, then distribute to authorized team members

**Connection**:
```bash
# SSH to bastion
ssh -i ~/.ssh/muso-key.pem ec2-user@bastion-host

# Tunnel to database
ssh -i ~/.ssh/muso-key.pem -L 5432:db-endpoint:5432 ec2-user@bastion-host
```

---

## CI/CD - Jenkins

### Infrastructure

- Runs on `system-prod` **ECS cluster** in separate VPC
- Jenkins home on **EFS**: `terraform/envs/system/app/jenkins_efs.tf`
- All system resources: `terraform/envs/system/`
- Jenkins ECS service: `terraform/envs/system/app/`
- Jenkins version: `terraform/envs/system/app/variables.tf#L39`

**Plugins**: Managed manually from Jenkins UI (JCasC planned)

### Jenkins Shared Library

Repository: [jenkins-shared-library](https://github.com/Muso-AI/jenkins-shared-library)

Provides reusable functions:
- Slack notifications
- ECS deployment
- Helm deployments

### GitHub Branch Source Plugin

Dynamically creates pipelines from GitHub organization repositories.

**Configuration**:
- GitHub App: [Installation 35059565](https://github.com/organizations/Muso-AI/settings/installations/35059565)
- Bot user: [muso-ci](https://github.com/muso-ci)
- Credentials: `keybase://team/musoai.infra/ci-cd/github-muso-ci-user.txt`
- Source pulls via SSH

### Jenkins Credential Provider

[AWS Secrets Manager Credentials Provider](https://plugins.jenkins.io/aws-secrets-manager-credentials-provider/) - credentials from AWS instead of Jenkins filesystem.

### Jenkins Authentication

- GitHub OAuth with Matrix-based authorization
- Login via GitHub organization membership

### Jenkins Agents

**Linux/Docker/Android Agent** (labels: `linux docker android`):
- EC2 instances with pre-installed Docker, Android SDK
- AMI: [jenkins-agent-18-05-2022](https://us-west-2.console.aws.amazon.com/ec2/home?region=us-west-2#ImageDetails:imageId=ami-095130a7f59500472)
- Key pair: `system-prod-jenkins-agents-ec2`
- Connected via SSH using AWS EC2 plugin
- Configuration: [Jenkins cloud config](https://jenkins.muso.ai/manage/cloud/system-prod/configure)

**macOS Agent** (label: `OSX_MC`):
- Hosted at [Macincloud](https://www.macincloud.com/)
- IP: `74.80.248.183`
- SSH credentials: `keybase://team/musoai.infra/ssh`
- Account: `keybase://team/musoai.infra/ci-cd/macincloud-build-agent.txt`

---

## Mobile CI/CD

[Fastlane](https://fastlane.tools/) automates iOS and Android builds.

**Flutter project config**: Injected via Jenkins credentials from AWS Secrets Manager:
- Secret: `mobile-app-config-prod`
- Usage: [Jenkinsfile#L35](https://github.com/Muso-AI/mobile/blob/develop/Jenkinsfile#L35)

### Android Build

- Jenkins: [mobile/Android](https://jenkins.muso.ai/job/mobile/job/Android/)
- Jenkinsfile: [android/Jenkinsfile](https://github.com/Muso-AI/mobile/blob/develop/android/Jenkinsfile)
- Build agent: EC2 with Android SDK
- **Google Play Release**: Fastlane uploads signed APK ([Jenkinsfile#L91](https://github.com/Muso-AI/mobile/blob/develop/android/Jenkinsfile#L91))
- Signing credentials: `keybase://team/musoai.infra/mobile/android`

### iOS Build

- Jenkins: [mobile/iOS](https://jenkins.muso.ai/job/mobile/job/iOS/)
- Jenkinsfile: [Jenkinsfile](https://github.com/Muso-AI/mobile/blob/develop/Jenkinsfile)
- Build agent: macOS (Macincloud)
- Flutter SDK: Installed manually on build agent
- **AppStore Release**: Fastlane uploads to TestFlight
- Certificates: `keybase://team/musoai.infra/mobile/ios`

**iOS Server Setup** (using rbenv/Bundler):
```bash
brew install rbenv ruby-build
echo 'eval "$(rbenv init -)"' >> ~/.zshrc
source ~/.zshrc
rbenv install 3.0.0
rbenv global 3.0.0
rbenv rehash
```

---

## Monitoring - CloudWatch

> **Note**: Dashboards and Alarms managed **manually** (IaC planned)

### Key Dashboards

| Dashboard | Purpose |
|-----------|---------|
| [core-backend-sqs-prod](https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#dashboards/dashboard/core-backend-sqs-prod) | SQS queue processing status, analytics |
| [core-backend-api-prod](https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#dashboards/dashboard/core-backend-api-prod) | Core Backend, ECS cluster, RDS, Redis |
| [industry-data-processing-prod](https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#dashboards/dashboard/industry-data-processing-prod) | Industry workers, API, EKS cluster |
| [data-capture](https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#dashboards/dashboard/data-capture) | Data capture services, logs |
| [analytics](https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#dashboards/dashboard/analytics) | Analytics capture services |
| [platform-data-processing-performance-prod](https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#dashboards/dashboard/platform-data-processing-performance-prod) | Platform data processing metrics |

### CloudWatch Alarms

Naming pattern: `[env][service]`
- [\[prod\]\[core\]](https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#alarmsV2:?~(search~'*5bprod*5d*5bcore*5d))
- [\[prod\]\[user-analytics\]](https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#alarmsV2:?~(search~'*5bprod*5d*5buser-analytics*5d))

---

## Backups

### MongoDB Atlas
- **Policy**: 7 daily backups
- **Point-in-time recovery**: Supported
- **Terraform**: `terraform/envs/prod/data/vars_prod.auto.tfvars#L135`

### RDS PostgreSQL
- **Policy**: 21 days retention
- **Recovery**: Create new instance from snapshot (not pg_dump)
- **Terraform**: `terraform/envs/prod/data/vars_prod.auto.tfvars#L52`

### ElastiCache Redis
- **Policy**: 7 days retention
- **Terraform**: `terraform/envs/prod/data/vars_prod.auto.tfvars#L89`

### EFS (Jenkins Home)
- **Service**: AWS Backup
- **Plan**: [aws/efs/automatic-backup-plan](https://us-west-2.console.aws.amazon.com/backup/home?region=us-west-2#backupplan/details/aws%2Fefs%2F73d922fb-9312-3a70-99c3-e69367f9fdad)
- **Terraform**: `terraform/envs/system/app/jenkins_efs.tf#L58`

---

## AWS Tags

Default tags defined in Terraform:
- `terraform/common/app/tf_providers.tf#L23`
- `terraform/common/app/locals.tf#L7`

> **Note**: AWS Tag policy not yet implemented ([planned](https://www.notion.so/Define-AWS-Tag-policies-677cb3fb71bf4daa89324f8fc13f53d3))

---

## IAM Management

**User management**: Manual (IAM groups, policy attachments)

**Application IAM roles**: Managed via Terraform with IRSA/ECS task roles
- Example: `terraform/common/app/svc_industry_proc_iam.tf`

> **Planned**: Migration to AWS SSO from IAM users

---

## Architecture Diagram

```text
Infrastructure Management
  Jenkins    --> deploys --> [ECS (Growth)] and [EKS (Catalog)]
  Terraform  --> manages --> [ECS (Growth)] and [EKS (Catalog)]
  CloudWatch --> monitors -> [ECS (Growth)] and [EKS (Catalog)]

ECS (Growth Cluster)
  - Static Websites
  - Credits Frontend
  - Core Backend API
  - Render Service
  - Workers

EKS (Catalog Cluster)
  - Capture Scheduler
  - Capture Interface
  - Analytics Worker
  - Industry API
  - Industry Workers
  - Feed Service

Shared Data Layer
  - Aurora DB
  - MongoDB Atlas
  - S3 Buckets
  - SQS Queues
```

---

## Quick Reference

### Service Locations

#### Growth Cluster (ECS)

| Service | Terraform | Team |
|---------|-----------|------|
| Core Backend API | `svc_core_api_ecs.tf` | Platform |
| Credits Frontend | - | Growth |
| Render Service | - | Platform |
| Workers | - | Growth |

#### Catalog Cluster (EKS)

| Service | Helm Chart | Team |
|---------|-----------|------|
| Industry API | `industry-data-processing/` | Catalog |
| Industry Workers | `industry-data-processing/` | Catalog |
| Analytics Worker | `analytics-worker/` | Catalog |
| Capture | `analytics-worker/` | Catalog |
| Feed Service | `feed-service/` | Platform |

### Common Commands

#### Terraform
```bash
cd terraform/envs/prod/app
terraform plan
terraform apply
```

#### LLM-Assisted Terraform Workflow

The Terraform structure is well understood by Claude Code and Cursor. Typical workflow:

1. Prompt the change you need (e.g., "add new ECS service for X")
2. LLM generates Terraform changes in `common/`
3. Run `terraform plan` in `envs/dev/app`
4. Review diff and apply to dev
5. Verify in dev environment
6. Apply same changes to prod

> "The good news is that this structure is really well understood by Cloud Code and Cursor as well. So in most cases I just prompt whatever I want then apply on dev." — Oleg (Jan 2026 KT)

#### Kubernetes
```bash
# Configure kubectl
aws eks update-kubeconfig --name core-prod --region us-west-2

# List pods
kubectl get pods -n industry-proc

# View logs
kubectl logs -f deployment/industry-api -n industry-proc

# View ConfigMap
kubectl get configmaps -n kube-system aws-auth -o yaml
```

#### SSH Tunnel
```bash
# To database via bastion
ssh -i ~/.ssh/muso-key.pem -L 5432:db-endpoint:5432 ec2-user@bastion-host
```

---

## Known Gaps

- Terraform lacks CI/CD automation for Airflow deployment
- No automated SSH key rotation process
- Jenkins plugins managed manually (JCasC planned)
- CloudWatch alarms/dashboards managed manually (IaC planned)
- IAM users managed manually (SSO migration planned)
- WAF rules managed manually outside Terraform
- EKS users all have `system:masters` (RBAC improvement needed)

### Jenkins CI/CD — Strategic Decision (Jan 2026)

Team explicitly decided to keep Jenkins despite considering GitHub Actions:
- Migration would require updating every repository's Jenkinsfile
- No dedicated DevOps resource since Ivan left (~1.5 years ago)
- Jenkins is working adequately for current needs
- Decision: **"If it's not broken, don't fix it"**

**If staying with Jenkins:** Consider upgrading to latest version to address security/compatibility issues.

### Manual Infrastructure (Not in Terraform)

These items are intentionally managed outside Terraform:
- **Platform management (MWAA)** — Managed by Andre/Platform team
- **CloudWatch alarms** — Created manually as needed
- **WAF rules** — Managed manually to fight external scrapers

---

## Appendix: Manual Changes

Changes added without Terraform:
- `distro.muso.ai` via Amplify: [Console](https://us-west-2.console.aws.amazon.com/amplify/apps/d1k0fz2koxsq9n/overview)

---

Last updated: 2026-01-31
