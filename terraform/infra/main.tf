/**
* # Cabalmail infra
*
* This terraform stack stands up AWS infrastructure needed for a Cabalmail system. See [README.md](../../README.md) at the root of this repository for general information.
*/

# -- Image tag resolution ------------------------------------
#
# The Docker build and Terraform workflows write the active image tag to SSM
# Parameter Store after a successful deployment.  Terraform always reads the
# tag from SSM so that cron and push-triggered runs use the correct image
# without requiring an explicit input.

data "aws_ssm_parameter" "deployed_image_tag" {
  name = "/cabal/deployed_image_tag"
}

# -- Phase 2 heartbeat parameter names -----------------------
#
# When var.monitoring is true, the monitoring module creates these as
# SSM SecureString placeholders and the operator populates each with a
# real Healthchecks ping URL after creating the corresponding check.
# Consumer modules read the parameter at runtime and skip the ping if
# the value still starts with "placeholder-".
#
# The strings here MUST match the names created in
# `terraform/infra/modules/monitoring/ssm.tf`. When monitoring is off,
# we pass empty strings so consumer modules skip the env var and IAM
# permission entirely.

locals {
  hc_ping_certbot         = var.monitoring ? "/cabal/healthcheck_ping_certbot_renewal" : ""
  hc_ping_dmarc           = var.monitoring ? "/cabal/healthcheck_ping_dmarc_ingest" : ""
  hc_ping_assign_osid     = var.monitoring ? "/cabal/healthcheck_ping_cognito_user_sync" : ""
  hc_ping_ecs_reconfigure = var.monitoring ? "/cabal/healthcheck_ping_ecs_reconfigure" : ""
}

# Create S3 bucket for React App
module "bucket" {
  source         = "./modules/s3"
  control_domain = var.control_domain
}

# Create Lambda layer for API functions
module "lambda_layers" {
  source = "./modules/lambda_layers"
  bucket = module.bucket.bucket
}

# Creates a Cognito User Pool
module "pool" {
  source                 = "./modules/user_pool"
  control_domain         = var.control_domain
  bucket                 = module.bucket.bucket
  bucket_arn             = module.bucket.bucket_arn
  ecs_cluster_name       = module.ecs.cluster_name
  healthcheck_ping_param = local.hc_ping_assign_osid
}

# Creates an AWS Certificate Manager certificate for use on load balancers and CloudFront
module "cert" {
  source         = "./modules/cert"
  control_domain = var.control_domain
  zone_id        = data.terraform_remote_state.zone.outputs.control_domain_zone_id
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
  private_zone_id     = module.vpc.private_zone.zone_id
  domains             = module.domains.domains
  layers              = module.lambda_layers.layers
  bucket              = module.bucket.bucket
  bucket_domain_name  = module.bucket.domain_name
  relay_ips           = module.vpc.relay_ips
  origin              = module.bucket.origin
  repo                = var.repo
  dev_mode            = var.prod ? false : true

  address_changed_topic_arn = module.ecs.sns_topic_arn
  admin_group_name          = module.pool.admin_group_name

  dmarc_healthcheck_ping_param = local.hc_ping_dmarc
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
  quiesced         = var.quiesced
}

# Creates a network load balancer shared by machines in the stack
module "load_balancer" {
  source            = "./modules/elb"
  public_subnet_ids = module.vpc.public_subnets[*].id
  vpc_id            = module.vpc.vpc.id
  zone_id           = data.terraform_remote_state.zone.outputs.control_domain_zone_id
  private_zone_id   = module.vpc.private_zone.zone_id
  control_domain    = var.control_domain
  cert_arn          = module.cert.cert_arn

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

# Creates ECR repositories for containerized mail services. The monitoring
# repos (uptime-kuma, ntfy, healthchecks) exist regardless of var.monitoring
# so the Docker workflow can push images unconditionally; only the ECS
# services are gated by the flag.
module "ecr" {
  source = "./modules/ecr"
  extra_repositories = [
    # Phase 1 / Phase 2 monitoring services
    "uptime-kuma",
    "ntfy",
    "healthchecks",
    # Phase 3 monitoring stack
    "prometheus",
    "alertmanager",
    "grafana",
    "cloudwatch-exporter",
    "blackbox-exporter",
    "node-exporter",
  ]
}

# ECS cluster, services, and task definitions for containerized mail tiers.
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
  image_tag           = data.aws_ssm_parameter.deployed_image_tag.value

  master_password = module.admin.master_password

  # Health-check tuning - raise these to keep containers alive for debugging.
  health_check_grace_period = 600
  deregistration_delay      = 120
  unhealthy_threshold       = 10

  healthcheck_ping_param = local.hc_ping_ecs_reconfigure

  quiesced = var.quiesced

  depends_on = [module.cert]
}

# Runs certbot on a schedule to renew Let's Encrypt certificates and restart ECS services
module "certbot_renewal" {
  source           = "./modules/certbot_renewal"
  control_domain   = var.control_domain
  zone_id          = data.terraform_remote_state.zone.outputs.control_domain_zone_id
  email            = var.email
  region           = var.aws_region
  image_tag        = data.aws_ssm_parameter.deployed_image_tag.value
  ecs_cluster_name = module.ecs.cluster_name
  ecs_service_names = [
    module.ecs.imap_service_name,
    module.ecs.smtp_in_service_name,
    module.ecs.smtp_out_service_name,
  ]

  healthcheck_ping_param = local.hc_ping_certbot
}

# Establishes a daily backup schedule for mail and address data
module "backup" {
  source = "./modules/backup"
  count  = var.backup ? 1 : 0
  table  = module.table.table_arn
  efs    = module.efs.efs_arn
}

# Phase 1 + 2 monitoring & alerting (0.7.0). See docs/0.7.0/monitoring-plan.md.
module "monitoring" {
  source = "./modules/monitoring"
  count  = var.monitoring ? 1 : 0

  control_domain     = var.control_domain
  region             = var.aws_region
  vpc_id             = module.vpc.vpc.id
  vpc_cidr_block     = module.vpc.vpc.cidr_block
  public_subnet_ids  = module.vpc.public_subnets[*].id
  private_subnet_ids = module.vpc.private_subnets[*].id
  zone_id            = data.terraform_remote_state.zone.outputs.control_domain_zone_id
  private_zone_id    = module.vpc.private_zone.zone_id
  cert_arn           = module.cert.cert_arn

  ecs_cluster_id                = module.ecs.cluster_arn
  ecs_cluster_capacity_provider = module.ecs.capacity_provider_name
  efs_id                        = module.efs.efs_id
  tier_log_group_names          = module.ecs.tier_log_group_names

  kuma_ecr_repository_url                = module.ecr.repository_urls["uptime-kuma"]
  ntfy_ecr_repository_url                = module.ecr.repository_urls["ntfy"]
  healthchecks_ecr_repository_url        = module.ecr.repository_urls["healthchecks"]
  prometheus_ecr_repository_url          = module.ecr.repository_urls["prometheus"]
  alertmanager_ecr_repository_url        = module.ecr.repository_urls["alertmanager"]
  grafana_ecr_repository_url             = module.ecr.repository_urls["grafana"]
  cloudwatch_exporter_ecr_repository_url = module.ecr.repository_urls["cloudwatch-exporter"]
  blackbox_exporter_ecr_repository_url   = module.ecr.repository_urls["blackbox-exporter"]
  node_exporter_ecr_repository_url       = module.ecr.repository_urls["node-exporter"]
  image_tag                              = data.aws_ssm_parameter.deployed_image_tag.value
  environment                            = var.environment

  user_pool_id     = module.pool.user_pool_id
  user_pool_arn    = module.pool.user_pool_arn
  user_pool_domain = module.pool.user_pool_domain

  lambda_bucket = module.bucket.bucket

  mail_domains                   = var.mail_domains
  healthchecks_registration_open = var.healthchecks_registration_open

  quiesced = var.quiesced
}
