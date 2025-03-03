/**
* # Cabalmail infra
*
* This terraform stack stands up AWS infrastructure needed for a Cabalmail system. See [README.md](../../README.md) at the root of this repository for general information.
*/

# Create S3 bucket for React App
module "bucket" {
  source         = "./modules/s3"
  control_domain = var.control_domain
}

# Create Lambda layers for other modules
module "lambda_layers" {
  source = "./modules/lambda_layers"
  bucket = module.bucket.bucket
}

# Creates a Cognito User Pool
module "pool" {
  source           = "./modules/user_pool"
  control_domain   = var.control_domain
  bucket           = module.bucket.bucket
  bucket_arn       = module.bucket.bucket_arn
  layers           = module.lambda_layers.layers
  ssm_document_arn = module.admin.ssm_document_arn
}

# Creates an AWS Certificate Manager certificate for use on load balancers and CloudFront and requests a Let's Encrypt certificate for use on EC2 instances
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
  layers              = module.lambda_layers.layers
  bucket              = module.bucket.domain
  relay_ips           = module.vpc.relay_ips
  origin              = module.bucket.origin
  repo                = var.repo
  dev_mode            = var.prod ? false : true
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
  source            = "./modules/elb"
  public_subnet_ids = module.vpc.public_subnets[*].id
  vpc_id            = module.vpc.vpc.id
  zone_id           = data.aws_ssm_parameter.zone.value
  control_domain    = var.control_domain
  cert_arn          = module.cert.cert_arn
}

# Creates an elastic file system for the mailstore
module "efs" {
  source             = "./modules/efs"
  vpc_id             = module.vpc.vpc.id
  vpc_cidr_block     = module.vpc.vpc.cidr_block
  private_subnet_ids = module.vpc.private_subnets[*].id
}

# Creates an auto-scale group for IMAP servers
module "imap" {
  source           = "./modules/asg"
  type             = "imap"
  private_subnets  = module.vpc.private_subnets
  vpc_id           = module.vpc.vpc.id
  control_domain   = var.control_domain
  target_groups    = [module.load_balancer.imap_tg]
  table_arn        = module.table.table_arn
  efs_dns          = module.efs.efs_dns
  user_pool_arn    = module.pool.user_pool_arn
  region           = var.aws_region
  ports            = [143, 993]
  private_ports    = [25]
  cidr_block       = var.cidr_block
  private_zone_id  = module.vpc.private_zone.zone_id
  private_zone_arn = module.vpc.private_zone.arn
  client_id        = module.pool.user_pool_client_id
  user_pool_id     = module.pool.user_pool_id
  scale            = var.imap_scale
  chef_license     = var.chef_license
  bucket           = module.bucket.bucket
  bucket_arn       = module.bucket.bucket_arn
  master_password  = module.admin.master_password
  depends_on       = [module.cert]
}

# Creates an auto-scale group for inbound SMTP servers
module "smtp_in" {
  source           = "./modules/asg"
  type             = "smtp-in"
  private_subnets  = module.vpc.private_subnets
  vpc_id           = module.vpc.vpc.id
  control_domain   = var.control_domain
  target_groups    = [module.load_balancer.relay_tg]
  table_arn        = module.table.table_arn
  efs_dns          = module.efs.efs_dns
  region           = var.aws_region
  ports            = [25, 465, 587]
  private_ports    = []
  cidr_block       = var.cidr_block
  private_zone_id  = module.vpc.private_zone.zone_id
  private_zone_arn = module.vpc.private_zone.arn
  client_id        = module.pool.user_pool_client_id
  user_pool_id     = module.pool.user_pool_id
  user_pool_arn    = module.pool.user_pool_arn
  scale            = var.smtpin_scale
  chef_license     = var.chef_license
  bucket           = module.bucket.bucket
  bucket_arn       = module.bucket.bucket_arn
  master_password  = module.admin.master_password
  depends_on       = [module.cert]
}

# Creates an auto-scale group for outbound SMTP servers
module "smtp_out" {
  source          = "./modules/asg"
  type            = "smtp-out"
  private_subnets = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc.id
  control_domain  = var.control_domain
  target_groups = [
    module.load_balancer.submission_tg,
    module.load_balancer.starttls_tg
  ]
  table_arn        = module.table.table_arn
  efs_dns          = module.efs.efs_dns
  region           = var.aws_region
  ports            = [25, 465, 587]
  private_ports    = []
  cidr_block       = var.cidr_block
  private_zone_id  = module.vpc.private_zone.zone_id
  private_zone_arn = module.vpc.private_zone.arn
  client_id        = module.pool.user_pool_client_id
  user_pool_id     = module.pool.user_pool_id
  user_pool_arn    = module.pool.user_pool_arn
  scale            = var.smtpout_scale
  chef_license     = var.chef_license
  bucket           = module.bucket.bucket
  bucket_arn       = module.bucket.bucket_arn
  master_password  = module.admin.master_password
  depends_on       = [module.cert]
}

# Establishes a daily backup schedule for mail and address data
module "backup" {
  source = "./modules/backup"
  count  = var.backup ? 1 : 0
  table  = module.table.table_arn
  efs    = module.efs.efs_arn
}
