output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = module.vpc.vpc_cidr
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "db_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = module.rds.db_endpoint
}

output "documents_bucket_name" {
  description = "S3 bucket name for receipt uploads"
  value       = module.s3.bucket_name
}

output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions IAM role - used in workflow files"
  value       = module.irsa.github_actions_role_arn
}

output "backend_role_arn" {
  description = "ARN of the backend IRSA role - annotated on the K8s service account"
  value       = module.irsa.backend_role_arn
}

output "frontend_ecr_url" {
  description = "ECR repository URL for the frontend image"
  value       = module.irsa.frontend_ecr_url
}

output "backend_ecr_url" {
  description = "ECR repository URL for the backend image"
  value       = module.irsa.backend_ecr_url
}
