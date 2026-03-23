# DevOps Configuration

## Prerequisites

- Terraform 1.5+
- AWS CLI v2
- kubectl
- helm
- Docker

## AWS Credentials

### Available Profiles

| Profile | Account | Resources | Region |
|---------|---------|-----------|--------|
| `muso-flagship-readonly` | Flagship | Athena, Glue (91 DBs), Route53 | us-west-2 |
| `muso-readonly` | Plaque | S3 buckets | us-west-2 |

```bash
# Configure read-only profiles
aws configure --profile muso-flagship-readonly
aws configure --profile muso-readonly

# Test access
aws athena list-named-queries --profile muso-flagship-readonly --region us-west-2
aws s3 ls --profile muso-readonly --region us-west-2

# For infrastructure management (write access)
aws configure --profile muso-dev
aws configure --profile muso-prod

# Or use environment variables
export AWS_ACCESS_KEY_ID=<key>
export AWS_SECRET_ACCESS_KEY=<secret>
export AWS_REGION=us-west-2
```

## Terraform Backend

Each environment uses S3 backend:

```hcl
# terraform/envs/dev/backend.tf
terraform {
  backend "s3" {
    bucket         = "muso-terraform-state"
    key            = "dev/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

## Environment Variables (tfvars)

```hcl
# terraform/envs/dev/terraform.tfvars
environment = "dev"
region      = "us-west-2"

vpc_cidr = "10.0.0.0/16"

ecs_instance_type = "t3.medium"
ecs_min_size      = 2
ecs_max_size      = 10

rds_instance_class = "db.t3.medium"
rds_multi_az       = false

redis_node_type    = "cache.t3.small"
redis_num_nodes    = 1
```

## Secrets Management

### AWS Secrets Manager

```bash
# Create secret
aws secretsmanager create-secret \
  --name muso/dev/database \
  --secret-string '{"username":"admin","password":"xxx"}'

# Retrieve in Terraform
data "aws_secretsmanager_secret_version" "db" {
  secret_id = "muso/${var.environment}/database"
}
```

### SSM Parameter Store

```bash
# Create parameter
aws ssm put-parameter \
  --name "/muso/dev/api/auth0-client-id" \
  --value "xxx" \
  --type "SecureString"

# Use in ECS task definition
secrets = [
  {
    name      = "AUTH0_CLIENT_ID"
    valueFrom = "/muso/${var.environment}/api/auth0-client-id"
  }
]
```

## ECS Task Definition

```hcl
resource "aws_ecs_task_definition" "core_backend" {
  family                   = "core-backend-${var.environment}"
  requires_compatibilities = ["EC2"]
  network_mode            = "bridge"
  
  container_definitions = jsonencode([{
    name  = "core-backend"
    image = "${var.ecr_repo}:${var.image_tag}"
    
    portMappings = [{
      containerPort = 4000
      hostPort      = 0
    }]
    
    environment = [
      { name = "NODE_ENV", value = var.environment },
      { name = "DB_HOST", value = module.rds.endpoint },
    ]
    
    secrets = [
      { name = "DB_PASSWORD", valueFrom = "arn:aws:secretsmanager:..." },
    ]
    
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/core-backend-${var.environment}"
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}
```

## EKS Node Groups

```hcl
resource "aws_eks_node_group" "analytics" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "analytics-${var.environment}"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = var.private_subnet_ids

  scaling_config {
    desired_size = 2
    max_size     = 10
    min_size     = 1
  }

  instance_types = ["r5.xlarge"]

  labels = {
    workload = "analytics"
  }

  taint {
    key    = "workload"
    value  = "analytics"
    effect = "NO_SCHEDULE"
  }
}
```

## Jenkins Configuration

Jenkins runs on ECS with EFS for persistence:

```hcl
# Jenkins controller
resource "aws_ecs_service" "jenkins" {
  name            = "jenkins"
  cluster         = module.ecs.cluster_id
  task_definition = aws_ecs_task_definition.jenkins.arn
  desired_count   = 1
  
  # EFS volume for Jenkins home
  volume {
    name = "jenkins-home"
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.jenkins.id
    }
  }
}
```
