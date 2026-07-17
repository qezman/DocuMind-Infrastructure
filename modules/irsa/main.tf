# ECR repos

# Frontend img repos
resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project}-frontend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project}-frontend"
  }
}

# Backend img repos
resource "aws_ecr_repository" "backend" {
  name                 = "${var.project}-backend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project}-backend"
  }
}

# Lifecycle policy - keep only the last 10 images per repo
resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Github Actions OIDC
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # sts.amazonaws.com - the audience GitHub Actions tokens target
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint - this is the SHA1 fingerprint of
  # GitHub's TLS certificate. AWS uses this to verify tokens are
  # genuinely from GitHub and not forged
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# IAM role that GitHub Actions assumes during CI runs
resource "aws_iam_role" "github_actions" {
  name = "${var.project}-${var.environment}-github-actions-role"

  # Trust policy - defines WHO can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # The GitHub OIDC provider is the trusted entity
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # Only allow tokens targeting AWS STS
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # The wildcard covers all branches and all workflow triggers
            # qezman/documind-frontend:*, qezman/documind-backend:*, etc.
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/documind-*:*"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project}-${var.environment}-github-actions-role"
  }
}

# Policy granting GitHub Actions
resource "aws_iam_role_policy" "github_actions" {
  name = "${var.project}-${var.environment}-github-actions-policy"
  role = aws_iam_role.github_actions.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR auth needed bfr any docker push
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        # GetAuthorizationToken is account-level, not resource-level
        Resource = "*"
      },
      {
        # ECR image operations — scoped to only documnind  repos
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = [
          aws_ecr_repository.frontend.arn,
          aws_ecr_repository.backend.arn
        ]
      }
    ]
  })
}

# IRSA - Backend Pod S3 Access
# IAM role that the backend Kubernetes pod assumes
resource "aws_iam_role" "backend" {
  name = "${var.project}-${var.environment}-backend-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # The EKS cluster's OIDC provider is the trusted entity
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # Only the documind-backend service account in the namespace can assume this role
            # Format: <oidc-url>:sub = system:serviceaccount:<namespace>:<sa-name>
            "${var.oidc_provider_url}:sub" = "system:serviceaccount:${var.project}:${var.project}-backend"
            "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project}-${var.environment}-backend-role"
  }
}

# Policy granting the backend pod S3 access
# Scoped to only the documents bucket - not all S3
resource "aws_iam_role_policy" "backend" {
  name = "${var.project}-${var.environment}-backend-policy"
  role = aws_iam_role.backend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]

        # /* all objects inside the bucket
        # not the bucket itself (least privilege)
        Resource = [
          var.documents_bucket_arn,
          "${var.documents_bucket_arn}/*"
        ]
      }
    ]
  })
}
