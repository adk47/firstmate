# DevOps API & Modules

## Terraform Module Structure

```
terraform/
├── envs/
│   ├── global/          # Shared resources
│   ├── system/          # Jenkins CI/CD
│   ├── dev/             # Development
│   └── prod/            # Production
├── modules/
│   ├── vpc/             # VPC, subnets, NAT
│   ├── ecs/             # ECS cluster, services
│   ├── eks/             # EKS cluster, node groups
│   ├── rds/             # PostgreSQL instances
│   ├── elasticache/     # Redis clusters
│   ├── alb/             # Application Load Balancers
│   ├── cloudfront/      # CDN distributions
│   └── security/        # Security groups, WAF
```

## Key Terraform Outputs

### VPC Module
```hcl
output "vpc_id" { value = aws_vpc.main.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "database_subnet_ids" { value = aws_subnet.database[*].id }
```

### ECS Module
```hcl
output "cluster_id" { value = aws_ecs_cluster.main.id }
output "cluster_name" { value = aws_ecs_cluster.main.name }
output "service_discovery_namespace" { value = aws_service_discovery_private_dns_namespace.main.id }
```

### EKS Module
```hcl
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "cluster_ca_certificate" { value = aws_eks_cluster.main.certificate_authority[0].data }
output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.eks.arn }
```

## Jenkins Pipeline

```groovy
// Jenkinsfile
pipeline {
    agent any
    
    stages {
        stage('Build') {
            steps {
                sh 'docker build -t ${ECR_REPO}:${GIT_COMMIT} .'
                sh 'docker push ${ECR_REPO}:${GIT_COMMIT}'
            }
        }
        
        stage('Deploy Dev') {
            when { branch 'develop' }
            steps {
                sh 'aws ecs update-service --cluster muso-dev --service core-backend --force-new-deployment'
            }
        }
        
        stage('Deploy Prod') {
            when { branch 'main' }
            steps {
                input message: 'Deploy to production?'
                sh 'aws ecs update-service --cluster muso-prod --service core-backend --force-new-deployment'
            }
        }
    }
}
```

## Traffic Flows

### Public Web
```
User -> Route53 -> CloudFront (WAF) -> Public ALB -> ECS (website/credits)
```

### API
```
Client -> Route53 -> Public ALB -> ECS (core-backend-api)
```

### Customer API
```
Partner -> Route53 -> API Gateway -> Public ALB -> ECS (core-backend)
```

### Static Assets
```
Browser -> CloudFront (assets CDN) -> S3 (via OAI)
```

## Common Terraform Commands

```bash
# Initialize
cd terraform/envs/dev
terraform init

# Plan
terraform plan -out=tfplan

# Apply
terraform apply tfplan

# Target specific resource
terraform apply -target=module.ecs.aws_ecs_service.core_backend
```

## Kubernetes Access

```bash
# Update kubeconfig
aws eks update-kubeconfig --name muso-{env} --region us-west-2

# Verify
kubectl get nodes

# Access logs
kubectl logs -n analytics deployment/analytics-worker

# Port forward
kubectl port-forward -n airflow svc/airflow-webserver 8080:8080
```
