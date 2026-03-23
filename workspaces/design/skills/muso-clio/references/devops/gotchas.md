# DevOps Gotchas

## Terraform State Locking

Always use DynamoDB for state locking:

```hcl
# WRONG - no locking, concurrent runs corrupt state
terraform {
  backend "s3" {
    bucket = "muso-terraform-state"
    key    = "dev/terraform.tfstate"
  }
}

# CORRECT - with locking
terraform {
  backend "s3" {
    bucket         = "muso-terraform-state"
    key            = "dev/terraform.tfstate"
    dynamodb_table = "terraform-locks"  # Add this!
    encrypt        = true
  }
}
```

## ECS Task Definition Drift

ECS task definitions are immutable. New deployments create new revisions:

```bash
# WRONG - assumes current revision
aws ecs update-service --service core-backend --task-definition core-backend

# CORRECT - specify revision or use :latest
aws ecs update-service --service core-backend --task-definition core-backend:42
# Or force new deployment with current
aws ecs update-service --service core-backend --force-new-deployment
```

## Security Group Circular Dependencies

```hcl
# WRONG - circular dependency
resource "aws_security_group" "a" {
  ingress {
    security_groups = [aws_security_group.b.id]
  }
}

resource "aws_security_group" "b" {
  ingress {
    security_groups = [aws_security_group.a.id]
  }
}

# CORRECT - use separate rules
resource "aws_security_group" "a" {}
resource "aws_security_group" "b" {}

resource "aws_security_group_rule" "a_from_b" {
  security_group_id        = aws_security_group.a.id
  source_security_group_id = aws_security_group.b.id
  ...
}
```

## EKS Node Group Updates

EKS node groups don't support in-place instance type changes:

```hcl
# WRONG - will fail
# Changing instance_types requires replacement
instance_types = ["r5.xlarge"]  # Changed from r5.large

# CORRECT - use launch template versioning
# Or create new node group, migrate workloads, delete old
```

## ALB Target Group Deregistration

Targets need time to drain connections:

```hcl
resource "aws_lb_target_group" "main" {
  # Add deregistration delay
  deregistration_delay = 30  # Default is 300, often too long
  
  # Enable connection draining
  stickiness {
    type    = "lb_cookie"
    enabled = false
  }
}
```

## RDS Parameter Changes

Some RDS parameters require reboot:

```hcl
# This change requires reboot
# Plan will show "apply_method = pending-reboot"
parameter {
  name  = "max_connections"
  value = "500"
  apply_method = "pending-reboot"  # Won't apply until reboot!
}
```

## Secrets in Terraform State

Secrets end up in state file:

```hcl
# WRONG - password in state
resource "aws_db_instance" "main" {
  password = var.db_password  # Stored in state!
}

# BETTER - use Secrets Manager
resource "aws_db_instance" "main" {
  password = random_password.db.result
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.db.result
}
```

## CloudFront Cache Invalidation

CloudFront caches aggressively. After deployment:

```bash
# Invalidate cache
aws cloudfront create-invalidation \
  --distribution-id E123456789 \
  --paths "/*"

# Or use versioned asset URLs
# /static/app.v1.2.3.js instead of /static/app.js
```

## Jenkins EFS Performance

Jenkins on EFS can be slow:

```hcl
# Use provisioned throughput for better performance
resource "aws_efs_file_system" "jenkins" {
  throughput_mode                 = "provisioned"
  provisioned_throughput_in_mibps = 50
}

# Or use GP3 EBS for faster I/O
```

## VPC Peering Route Tables

VPC peering requires routes in BOTH VPCs:

```hcl
# Route in our VPC
resource "aws_route" "to_mongodb" {
  route_table_id            = var.private_route_table_id
  destination_cidr_block    = var.mongodb_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.mongodb.id
}

# DON'T FORGET: Route in MongoDB VPC (done in Atlas console)
```

## IAM Policy Size Limits

IAM policies have 6KB limit:

```hcl
# WRONG - huge inline policy
resource "aws_iam_role_policy" "big" {
  policy = jsonencode({
    # 100+ statements...  # Will fail!
  })
}

# CORRECT - use managed policies or multiple policies
resource "aws_iam_policy" "s3" { ... }
resource "aws_iam_policy" "sqs" { ... }
resource "aws_iam_role_policy_attachment" "s3" { ... }
resource "aws_iam_role_policy_attachment" "sqs" { ... }
```

## Terraform Provider Version Pinning

Always pin provider versions:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"  # Pin major version
    }
  }
}
```

## ECS Deployment Sequence

When deploying a new Python service to ECS (in the `devops` repo):

### Required Order
1. **Create ECR repository first** — Run `terraform apply` in `devops/global/ecr/`
2. **Push Docker image** — Jenkins builds and pushes to ECR on branch merge
3. **Deploy app infrastructure** — Run `terraform apply` in `devops/environments/dev/app/`
4. **Verify health check** — ALB checks `/api/v1/health` endpoint

### Jenkins Pipeline Branch Conditions
In `Jenkinsfile` (uses jenkins-shared-library), ensure branch conditions include `develop`:
```groovy
// Example from Jenkinsfile - actual syntax may vary by shared library version
// WRONG - missing develop (won't auto-deploy to dev)
branches: ['master', 'PR-*']

// CORRECT - enables auto-deploy to dev environment
branches: ['develop', 'master', 'PR-*']
```

### Post-Deployment Verification
1. Check ECS console for running tasks (desired count > 0)
2. Verify ALB target group shows healthy targets
3. Check CloudWatch logs for startup errors
4. Test health endpoint: `curl https://<service>.muso.ai/api/v1/health`

### Common Failures
| Error | Cause | Fix |
|-------|-------|-----|
| "ECR repository does not exist" | Infra deployed before ECR | Apply ECR first in `global/ecr/` |
| "Service not active exception" | Parallel deploy/destroy | Wait for current operation |
| Docker push not happening | Branch not in auto-deploy list | Add `develop` to Jenkinsfile branches |
| Health check failing | Wrong path or service crash | Check CloudWatch logs, verify `/api/v1/health` |

### Rollback
To rollback a bad deployment:
```bash
# Force redeploy previous task definition revision
aws ecs update-service --cluster common --service <name> \
  --task-definition <name>:<previous-revision> --force-new-deployment
```

Source: KT 2026-01-30
