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
  ecs_cluster_name = module.ecs.cluster_name
}

# Creates an AWS Certificate Manager certificate for use on load balancers and CloudFront and requests a Let's Encrypt certificate for use on EC2 instances
module "cert" {
  source         = "./modules/cert"
  control_domain = var.control_domain
  zone_id        = data.terraform_remote_state.zone.outputs.control_domain_zone_id
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
  zone_id             = data.terraform_remote_state.zone.outputs.control_domain_zone_id
  domains             = module.domains.domains
  layers              = module.lambda_layers.layers
  bucket              = module.bucket.bucket
  bucket_domain_name  = module.bucket.domain_name
  relay_ips           = module.vpc.relay_ips
  origin              = module.bucket.origin
  repo                = var.repo
  dev_mode            = var.prod ? false : true

  address_changed_topic_arn = module.ecs.sns_topic_arn
}

# Creates a DynamoDB table for storing address data
module "table" {
  source = "./modules/table"
}

# Creates the VPC and network infrastructure
module "vpc" {
  source           = "./modules/vpc"
  use_nat_instance = true
  cidr_block       = var.cidr_block
  control_domain   = var.control_domain
  az_list          = var.availability_zones
  zone_id          = data.terraform_remote_state.zone.outputs.control_domain_zone_id
}

# Creates a network load balancer shared by machines in the stack
module "load_balancer" {
  source            = "./modules/elb"
  public_subnet_ids = module.vpc.public_subnets[*].id
  vpc_id            = module.vpc.vpc.id
  zone_id           = data.terraform_remote_state.zone.outputs.control_domain_zone_id
  control_domain    = var.control_domain
  cert_arn          = module.cert.cert_arn

  # Phase 7 cutover: forward production listeners to ECS target groups
  ecs_imap_target_group_arn       = module.ecs.imap_target_group_arn
  ecs_relay_target_group_arn      = module.ecs.relay_target_group_arn
  ecs_submission_target_group_arn = module.ecs.submission_target_group_arn
  ecs_starttls_target_group_arn   = module.ecs.starttls_target_group_arn
}

# Creates an elastic file system for the mailstore
module "efs" {
  source             = "./modules/efs"
  vpc_id             = module.vpc.vpc.id
  vpc_cidr_block     = module.vpc.vpc.cidr_block
  private_subnet_ids = module.vpc.private_subnets[*].id
}

# Creates ECR repositories for containerized mail services
module "ecr" {
  source = "./modules/ecr"
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

# ECS cluster, services, and task definitions for containerized mail tiers.
# Creates its own ip-type target groups so the ASG modules above can continue
# serving traffic through the existing instance-type target groups during the
# parallel-run transition period (Phase 7).
module "ecs" {
  source = "./modules/ecs"

  private_subnets = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc.id
  cidr_block      = var.cidr_block
  region          = var.aws_region
  control_domain  = var.control_domain

  table_arn = module.table.table_arn
  efs_id    = module.efs.efs_id

  user_pool_arn = module.pool.user_pool_arn
  user_pool_id  = module.pool.user_pool_id
  client_id     = module.pool.user_pool_client_id

  ecr_repository_urls = module.ecr.repository_urls
  image_tag           = var.image_tag

  master_password = module.admin.master_password

  depends_on = [module.cert]
}

# Establishes a daily backup schedule for mail and address data
module "backup" {
  source = "./modules/backup"
  count  = var.backup ? 1 : 0
  table  = module.table.table_arn
  efs    = module.efs.efs_arn
}
