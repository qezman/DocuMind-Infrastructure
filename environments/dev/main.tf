

data "aws_caller_identity" "current" {}


module "vpc" {
  source = "../../modules/vpc"

  project            = var.project
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

module "eks" {
  source             = "../../modules/eks"
  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  node_desired_size  = var.node_desired_size
  node_max_size      = var.node_max_size
}

module "rds" {
  source                     = "../../modules/rds"
  project                    = var.project
  environment                = var.environment
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id
  db_username                = var.db_username
  db_password                = var.db_password
}

module "s3" {
  source         = "../../modules/s3"
  project        = var.project
  environment    = var.environment
  aws_account_id = data.aws_caller_identity.current.account_id
}

module "irsa" {
  source = "../../modules/irsa"

  project              = var.project
  environment          = var.environment
  aws_account_id       = data.aws_caller_identity.current.account_id
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider_url
  documents_bucket_arn = module.s3.bucket_arn
}


module "external_secrets" {
  source            = "../../modules/external-secrets"
  project           = var.project
  environment       = var.environment
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  database_url      = var.database_url
  jwt_secret        = var.jwt_secret
  gemini_api_key    = var.gemini_api_key
}

module "dns" {
  source              = "../../modules/dns"
  ingress_lb_hostname = "k8s-ingressn-ingressn-bfc0403c1f-d693cceaae0e0419.elb.us-east-1.amazonaws.com"
}
