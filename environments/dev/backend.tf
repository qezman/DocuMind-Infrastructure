terraform {
  backend "s3" {
    bucket         = "document-terraform-state"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "documind-terraform-locks"
    encrypt        = true
  }
}
