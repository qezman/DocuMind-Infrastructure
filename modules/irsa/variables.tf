variable "project" {
  description = "Project name used as a prefix on all resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_account_id" {
  description = "ARN of the EKS OIDC provider (used for IRSA policy)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider (used for IRSA trust policy)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS OIDC provider (used for IRSA trust policy)"
  type        = string
}

variable "documents_bucket_arn" {
  description = "ARN of the S3 dosuments bucket (scopes the backend IAM policy)"
  type        = string
}

variable "github_org" {
  description = "Github username or organization that owns the repos"
  type        = string
  default     = "qezman"
}
