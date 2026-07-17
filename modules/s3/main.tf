# S3 bucket for documents image uploads
resource "aws_s3_bucket" "documents" {
  bucket = "${var.project}-${var.environment}-documents-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project}-${var.environment}-documents"
  }
}

data "aws_caller_identity" "current" {}


# Block all public across to the bucket
resource "aws_s3_bucket_public_access_block" "documents" {
  bucket = aws_s3_bucket.documents.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS configuration
resource "aws_s3_bucket_cors_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  cors_rule {
    allowed_origins = ["*"]

    # PUT: browser uploads using a presigned URL
    # GET: for downloading/viewing documents
    allowed_methods = ["PUT", "GET"]

    allowed_headers = ["*"]

    # time the browser caches the CORS preflight response
    max_age_seconds = 3000
  }
}

# Lifecycle rule
resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    id     = "expire-old-documents"
    status = "Enabled"

    # applies to all objects in the bucket
    filter {}

    expiration {
      days = 90
    }
  }
}
