terraform {
  backend "s3" {
    bucket       = "documind-terraform-state-332130072211"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
    profile      = "documind"
  }
}
