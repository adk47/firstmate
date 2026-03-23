# DevOps Patterns

## Multi-Environment Pattern

```hcl
# terraform/envs/dev/main.tf
module "vpc" {
  source = "../../modules/vpc"
  
  environment = "dev"
  cidr_block  = "10.0.0.0/16"
}

module "ecs" {
  source = "../../modules/ecs"
  
  environment       = "dev"
  vpc_id           = module.vpc.vpc_id
  private_subnets  = module.vpc.private_subnet_ids
  
  # Dev-specific settings
  instance_type = "t3.medium"
  min_size      = 2
  max_size      = 5
}
```

## Service Discovery Pattern

ECS services discover each other via Cloud Map:

```hcl
resource "aws_service_discovery_service" "core_backend" {
  name = "core-backend"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

# Access via: core-backend.muso.local
```

## Blue-Green Deployment Pattern

```hcl
resource "aws_lb_target_group" "blue" {
  name     = "core-backend-blue"
  port     = 4000
  protocol = "HTTP"
  vpc_id   = var.vpc_id
}

resource "aws_lb_target_group" "green" {
  name     = "core-backend-green"
  port     = 4000
  protocol = "HTTP"
  vpc_id   = var.vpc_id
}

# Switch via listener rule weight
resource "aws_lb_listener_rule" "core_backend" {
  listener_arn = aws_lb_listener.https.arn
  
  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.blue.arn
        weight = 100  # Change to 0 for green
      }
      target_group {
        arn    = aws_lb_target_group.green.arn
        weight = 0    # Change to 100 for green
      }
    }
  }
}
```

## Auto Scaling Pattern

```hcl
# ECS Service Auto Scaling
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 10
  min_capacity       = 2
  resource_id        = "service/${var.cluster_name}/${var.service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 70.0
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
```

## Security Group Pattern

```hcl
# Layered security groups
resource "aws_security_group" "alb" {
  name   = "alb-${var.environment}"
  vpc_id = var.vpc_id
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs" {
  name   = "ecs-${var.environment}"
  vpc_id = var.vpc_id
  
  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]  # Only from ALB
  }
}

resource "aws_security_group" "rds" {
  name   = "rds-${var.environment}"
  vpc_id = var.vpc_id
  
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]  # Only from ECS
  }
}
```

## IAM Role Pattern (EKS IRSA)

```hcl
# Service account for pod to access AWS
resource "aws_iam_role" "analytics_worker" {
  name = "analytics-worker-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_issuer}:sub" = "system:serviceaccount:analytics:analytics-worker"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "analytics_worker_s3" {
  role       = aws_iam_role.analytics_worker.name
  policy_arn = aws_iam_policy.s3_access.arn
}
```

## Helm Deployment Pattern

```bash
# Install/upgrade with environment values
helm upgrade --install core-backend ./charts/core-backend \
  -n muso \
  -f values.yaml \
  -f values-${ENVIRONMENT}.yaml \
  --set image.tag=${GIT_COMMIT}
```
