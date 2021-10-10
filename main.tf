provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      managed_by_terraform = "y"
      terraform_repo       = var.repo
    }
  }
}

module "cabal_cert" {
  source         = "./modules/cert"
  control_domain = var.control_domain
  zone_id        = var.zone_id
}

module "cabal_cookbooks" {
  source = "./modules/cookbooks"
}

module "cabal_pool" {
  source         = "./modules/user_pool"
  control_domain = var.control_domain
  zone_id        = var.zone_id
}

module "cabal_admin" {
  source              = "./modules/app"
  control_domain      = var.control_domain
  user_pool_id        = module.cabal_pool.user_pool_id
  user_pool_client_id = module.cabal_pool.user_pool_client_id
  region              = var.aws_region
  cert_arn            = module.cabal_cert.cert_arn
  zone_id             = var.zone_id
}

module "cabal_table" {
  source     = "./modules/table"
}

module "cabal_vpc" {
  source     = "./modules/vpc"
  cidr_block = var.cidr_block
  az_list    = var.availability_zones
}

module "cabal_load_balancer" {
  source         = "./modules/elb"
  public_subnets = module.cabal_vpc.public_subnets
  vpc            = module.cabal_vpc.vpc
  control_domain = var.control_domain
  zone_id        = var.zone_id
  cert_arn       = module.cabal_cert.cert_arn
}

module "cabal_efs" {
  source           = "./modules/efs"
  vpc              = module.cabal_vpc.vpc
  private_subnets  = module.cabal_vpc.private_subnets
}

module "cabal_imap" {
  source           = "./modules/imap"
  private_subnets  = module.cabal_vpc.private_subnets
  vpc              = module.cabal_vpc.vpc
  control_domain   = var.control_domain
  artifact_bucket  = module.cabal_cookbooks.bucket.id
  target_group_arn = module.cabal_load_balancer.imap_tg.arn
  table_arn        = module.cabal_table.table_arn
  s3_arn           = module.cabal_cookbooks.bucket.arn
  efs_dns          = module.cabal_efs.efs_dns
  scale            = var.imap_scale
  depends_on       = [
    module.cabal_cookbooks
  ]
}

module "cabal_smtp_in" {
  source           = "./modules/smtp"
  type             = "in"
  private_subnets  = module.cabal_vpc.private_subnets
  vpc              = module.cabal_vpc.vpc
  control_domain   = var.control_domain
  artifact_bucket  = module.cabal_cookbooks.bucket.id
  target_group_arn = module.cabal_load_balancer.imap_tg.arn
  table_arn        = module.cabal_table.table_arn
  s3_arn           = module.cabal_cookbooks.bucket.arn
  efs_dns          = module.cabal_efs.efs_dns
  scale            = var.smtpin_scale
  depends_on       = [
    module.cabal_cookbooks
  ]
}

module "cabal_smtp_out" {
  source           = "./modules/smtp"
  type             = "out"
  private_subnets  = module.cabal_vpc.private_subnets
  vpc              = module.cabal_vpc.vpc
  control_domain   = var.control_domain
  artifact_bucket  = module.cabal_cookbooks.bucket.id
  target_group_arn = module.cabal_load_balancer.imap_tg.arn
  table_arn        = module.cabal_table.table_arn
  s3_arn           = module.cabal_cookbooks.bucket.arn
  efs_dns          = module.cabal_efs.efs_dns
  scale            = var.smtpout_scale
  depends_on       = [
    module.cabal_cookbooks
  ]
}

# TODO
# Create user pool
# - auth sufficient pam_exec.so expose_authtok /usr/bin/cognito.bash
# - COGNITO_PASSWORD=`cat -`
# - COGNITO_USER="${PAM_USER}"
# - AUTH_TYPE="${PAM_TYPE}"
# - https://docs.aws.amazon.com/cli/latest/reference/cognito-idp/admin-initiate-auth.html
# Create lambda/api-gateway admin application
# Add some users