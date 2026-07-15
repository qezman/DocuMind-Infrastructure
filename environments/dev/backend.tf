terraform {
  backend "s3" {
    bucket       = "documind-terraform-state-560205084952"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
    profile      = "documind"
  }
}
