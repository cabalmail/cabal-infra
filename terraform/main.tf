provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      managed_by_terraform = "y"
      terraform_repo       = var.repo
    }
  }
}

# Creates an AWS Certificate Manager certificate for use on load balancers and CloudFront
module "cabal_cert" {
  source         = "./modules/cert"
  control_domain = var.control_domain
  zone_id        = var.zone_id
}

# Sets up Route 53 hosted zones for mail domains
module "cabal_domains" {
  source       = "./modules/domains"
  mail_domains = var.mail_domains
}

# Creates an s3 bucket and uploads cookbooks to it for retrieval by ec2 instances
module "cabal_cookbook" {
  source = "./modules/cookbook"
}

# Creates a Cognito User Pool
module "cabal_pool" {
  source         = "./modules/user_pool"
  control_domain = var.control_domain
  zone_id        = var.zone_id
}

# Infrastructure and code for the administrative web site
module "cabal_admin" {
  source              = "./modules/app"
  control_domain      = var.control_domain
  user_pool_id        = module.cabal_pool.user_pool_id
  user_pool_client_id = module.cabal_pool.user_pool_client_id
  region              = var.aws_region
  cert_arn            = module.cabal_cert.cert_arn
  zone_id             = var.zone_id
  domains             = module.cabal_domains.domains
  relay_ips           = module.cabal_vpc.relay_ips
}

# Creates a DynamoDB table for storing address data
module "cabal_table" {
  source     = "./modules/table"
}

# Creates the VPC and network infrastructure
module "cabal_vpc" {
  source     = "./modules/vpc"
  cidr_block = var.cidr_block
  az_list    = var.availability_zones
}

# Creates a network load balancer shared by machines in the stack
module "cabal_load_balancer" {
  source         = "./modules/elb"
  public_subnets = module.cabal_vpc.public_subnets
  vpc            = module.cabal_vpc.vpc
  control_domain = var.control_domain
  zone_id        = var.zone_id
  cert_arn       = module.cabal_cert.cert_arn
}

# Creates an elastic file system for the mailstore
module "cabal_efs" {
  source           = "./modules/efs"
  vpc              = module.cabal_vpc.vpc
  private_subnets  = module.cabal_vpc.private_subnets
}

# Creates an auto-scale group for IMAP servers
module "cabal_imap" {
  source           = "./modules/asg"
  type             = "imap"
  private_subnets  = module.cabal_vpc.private_subnets
  vpc              = module.cabal_vpc.vpc
  control_domain   = var.control_domain
  artifact_bucket  = module.cabal_cookbook.bucket.id
  target_group_arn = module.cabal_load_balancer.imap_tg
  table_arn        = module.cabal_table.table_arn
  s3_arn           = module.cabal_cookbook.bucket.arn
  efs_dns          = module.cabal_efs.efs_dns
  user_pool_arn    = module.cabal_pool.user_pool_arn
  region           = var.aws_region
  ports            = [143, 993]
  client_id        = module.cabal_pool.user_pool_client_id
  user_pool_id     = module.cabal_pool.user_pool_id
  scale            = var.imap_scale
  chef_license     = var.chef_license
}

# Creates an auto-scale group for inbound SMTP servers
module "cabal_smtp_in" {
  source           = "./modules/asg"
  type             = "smtp-in"
  private_subnets  = module.cabal_vpc.private_subnets
  vpc              = module.cabal_vpc.vpc
  control_domain   = var.control_domain
  artifact_bucket  = module.cabal_cookbook.bucket.id
  target_group_arn = module.cabal_load_balancer.relay_tg.arn
  table_arn        = module.cabal_table.table_arn
  s3_arn           = module.cabal_cookbook.bucket.arn
  efs_dns          = module.cabal_efs.efs_dns
  region           = var.aws_region
  ports            = [25, 465, 587]
  client_id        = module.cabal_pool.user_pool_client_id
  user_pool_id     = module.cabal_pool.user_pool_id
  user_pool_arn    = module.cabal_pool.user_pool_arn
  scale            = var.smtpin_scale
  chef_license     = var.chef_license
}

# Creates an auto-scale group for outbound SMTP servers
module "cabal_smtp_out" {
  source           = "./modules/asg"
  type             = "smtp-out"
  private_subnets  = module.cabal_vpc.private_subnets
  vpc              = module.cabal_vpc.vpc
  control_domain   = var.control_domain
  artifact_bucket  = module.cabal_cookbook.bucket.id
  target_group_arn = module.cabal_load_balancer.submission_tg.arn
  table_arn        = module.cabal_table.table_arn
  s3_arn           = module.cabal_cookbook.bucket.arn
  efs_dns          = module.cabal_efs.efs_dns
  region           = var.aws_region
  ports            = [465, 587]
  client_id        = module.cabal_pool.user_pool_client_id
  user_pool_id     = module.cabal_pool.user_pool_id
  user_pool_arn    = module.cabal_pool.user_pool_arn
  scale            = var.smtpout_scale
  chef_license     = var.chef_license
}