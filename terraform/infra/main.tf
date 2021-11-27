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
# and requests a Let's Encrypt certificate for use on EC2 instances
module "cert" {
  source         = "./modules/cert"
  control_domain = var.control_domain
  zone_id        = data.aws_ssm_parameter.zone.value
  prod           = var.prod
  email          = var.email
}

# Sets up Route 53 hosted zones for mail domains
module "domains" {
  source       = "./modules/domains"
  mail_domains = var.mail_domains
}

# Creates an s3 bucket and uploads cookbooks to it for retrieval by ec2 instances
module "cookbook" {
  source = "./modules/cookbook"
}

# Creates a Cognito User Pool
module "pool" {
  source         = "./modules/user_pool"
  control_domain = var.control_domain
  zone_id        = data.aws_ssm_parameter.zone.value
}

# Infrastructure and code for the administrative web site
module "admin" {
  source              = "./modules/app"
  control_domain      = var.control_domain
  user_pool_id        = module.pool.user_pool_id
  user_pool_client_id = module.pool.user_pool_client_id
  region              = var.aws_region
  cert_arn            = module.cert.cert_arn
  zone_id             = data.aws_ssm_parameter.zone.value
  domains             = module.domains.domains
  relay_ips           = module.vpc.relay_ips
}

# Creates a DynamoDB table for storing address data
module "table" {
  source = "./modules/table"
}

# Creates the VPC and network infrastructure
module "vpc" {
  source         = "./modules/vpc"
  cidr_block     = var.cidr_block
  control_domain = var.control_domain
  az_list        = var.availability_zones
  zone_id        = data.aws_ssm_parameter.zone.value
}

# Creates a network load balancer shared by machines in the stack
module "load_balancer" {
  source         = "./modules/elb"
  public_subnets = module.vpc.public_subnets
  vpc            = module.vpc.vpc
  control_domain = var.control_domain
  zone_id        = data.aws_ssm_parameter.zone.value
  cert_arn       = module.cert.cert_arn
}

# Creates an elastic file system for the mailstore
module "efs" {
  source          = "./modules/efs"
  vpc             = module.vpc.vpc
  private_subnets = module.vpc.private_subnets
}

# Creates an auto-scale group for IMAP servers
module "imap" {
  source          = "./modules/asg"
  type            = "imap"
  private_subnets = module.vpc.private_subnets
  vpc             = module.vpc.vpc
  control_domain  = var.control_domain
  artifact_bucket = module.cookbook.bucket.id
  target_groups   = [module.load_balancer.imap_tg]
  table_arn       = module.table.table_arn
  s3_arn          = module.cookbook.bucket.arn
  efs_dns         = module.efs.efs_dns
  user_pool_arn   = module.pool.user_pool_arn
  region          = var.aws_region
  ports           = [143, 993]
  private_ports   = [25]
  cidr_block      = var.cidr_block
  private_zone    = module.vpc.private_zone
  client_id       = module.pool.user_pool_client_id
  user_pool_id    = module.pool.user_pool_id
  scale           = var.imap_scale
  chef_license    = var.chef_license
  depends_on      = [ module.cert ]
}

# Creates an auto-scale group for inbound SMTP servers
module "smtp_in" {
  source          = "./modules/asg"
  type            = "smtp-in"
  private_subnets = module.vpc.private_subnets
  vpc             = module.vpc.vpc
  control_domain  = var.control_domain
  artifact_bucket = module.cookbook.bucket.id
  target_groups   = [module.load_balancer.relay_tg]
  table_arn       = module.table.table_arn
  s3_arn          = module.cookbook.bucket.arn
  efs_dns         = module.efs.efs_dns
  region          = var.aws_region
  ports           = [25, 465, 587]
  private_ports   = []
  cidr_block      = var.cidr_block
  private_zone    = module.vpc.private_zone
  client_id       = module.pool.user_pool_client_id
  user_pool_id    = module.pool.user_pool_id
  user_pool_arn   = module.pool.user_pool_arn
  scale           = var.smtpin_scale
  chef_license    = var.chef_license
  depends_on      = [ module.cert ]
}

# Creates an auto-scale group for outbound SMTP servers
module "smtp_out" {
  source          = "./modules/asg"
  type            = "smtp-out"
  private_subnets = module.vpc.private_subnets
  vpc             = module.vpc.vpc
  control_domain  = var.control_domain
  artifact_bucket = module.cookbook.bucket.id
  target_groups   = [
    module.load_balancer.submission_tg,
    module.load_balancer.starttls_tg
  ]
  table_arn       = module.table.table_arn
  s3_arn          = module.cookbook.bucket.arn
  efs_dns         = module.efs.efs_dns
  region          = var.aws_region
  ports           = [25, 465, 587]
  private_ports   = []
  cidr_block      = var.cidr_block
  private_zone    = module.vpc.private_zone
  client_id       = module.pool.user_pool_client_id
  user_pool_id    = module.pool.user_pool_id
  user_pool_arn   = module.pool.user_pool_arn
  scale           = var.smtpout_scale
  chef_license    = var.chef_license
  depends_on      = [ module.cert ]
}