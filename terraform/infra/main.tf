/**
* # Cabalmail infra
*
* This terraform stack stands up AWS infrastructure needed for a Cabalmail system. See [README.md](../../README.md) at the root of this repository for general information.
*/

# -- Image tag resolution ------------------------------------
#
# app.yml's docker job builds per-tier images and rolls the ECS
# services out of band, rebuilding only the tiers whose inputs changed
# (docs/0.10.x/per-tier-docker-deploy-plan.md), so sibling tiers
# legitimately diverge in image tag. infra.yml's plan job
# (.github/scripts/refresh-ssm-from-running.sh) copies each tier's
# RUNNING image tag into a per-tier SSM parameter before every plan,
# and Terraform reads those parameters here, so a topology change that
# regenerates a task definition re-pins each tier to the tag that tier
# is actually running - not to whichever tier deployed most recently.
#
# The per-tier parameters are seeded with the bootstrap sentinel and
# thereafter written only by CI (ignore_changes = [value]); referencing
# the resource attribute reads the refreshed real value back at plan
# time. The legacy global parameter is hand-provisioned at account
# genesis (it is not Terraform-managed, and it survives an environment
# teardown) and is kept as the fallback for any tier whose per-tier key
# still holds the sentinel: that is the cutover path for environments
# that predate the per-tier keys, and the bootstrap path for brand-new
# environments, where the legacy key holds the sentinel too and every
# consuming module falls back to its public placeholder image.

data "aws_ssm_parameter" "deployed_image_tag" {
  name = "/cabal/deployed_image_tag"
}

locals {
  # Everything app.yml's docker matrix can build and deploy. Core mail
  # tiers always; sinkhole and the monitoring tiers are gated per
  # environment (vars.TF_VAR_SINKHOLE / TF_VAR_MONITORING), but their
  # tag parameters exist everywhere for the same reason their ECR repos
  # do - so the deploy pipeline never has to special-case a gate flip.
  core_mail_tiers = ["imap", "smtp-in", "smtp-out"]
  monitoring_tiers = [
    "uptime-kuma",
    "ntfy",
    "healthchecks",
    "prometheus",
    "alertmanager",
    "grafana",
    "cloudwatch-exporter",
    "blackbox-exporter",
    "node-exporter",
  ]
  docker_tiers = concat(local.core_mail_tiers, ["sinkhole"], local.monitoring_tiers)

  # Must match the placeholder_image_tag locals in the ecs, monitoring,
  # and certbot_renewal modules.
  bootstrap_sentinel = "bootstrap-placeholder"
}

# CKV2_AWS_34 (SecureString) is baselined for this resource: image tags
# are deploy metadata, not secrets, so a plaintext String is deliberate
# (same posture as the cf_distribution and sinkhole_mode parameters).
resource "aws_ssm_parameter" "tier_image_tag" {
  for_each    = toset(local.docker_tiers)
  name        = "/cabal/deployed_image_tag/${each.value}"
  description = "Image tag running on the cabal-${each.value} tier. Written by .github/scripts/refresh-ssm-from-running.sh; Terraform only seeds it."
  type        = "String"
  value       = local.bootstrap_sentinel

  lifecycle {
    ignore_changes = [value]
  }
}

locals {
  tier_image_tags = {
    for tier in local.docker_tiers :
    tier => (
      aws_ssm_parameter.tier_image_tag[tier].value == local.bootstrap_sentinel
      ? data.aws_ssm_parameter.deployed_image_tag.value
      : aws_ssm_parameter.tier_image_tag[tier].value
    )
  }
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

# Shared S3 server-access-log target for the content buckets (admin, www,
# cache). Each of those modules attaches an aws_s3_bucket_logging that
# writes here under its own prefix. See modules/s3_access_logs.
module "s3_access_logs" {
  source         = "./modules/s3_access_logs"
  control_domain = var.control_domain
}

# Create S3 bucket for React App
module "bucket" {
  source             = "./modules/s3"
  control_domain     = var.control_domain
  access_logs_bucket = module.s3_access_logs.bucket
}

# Phase 5 of docs/0.10.x/resilience-continuity-hardening-plan.md moved
# the admin bucket's policy from the s3 module to the app module so
# the OAC grant can reference the distribution ARN without the two
# modules referencing each other. Adopt the existing policy in place
# instead of delete-and-recreate, which would race and could leave the
# live bucket policyless for a window. Safe to delete this block once
# every environment has applied past it.
moved {
  from = module.bucket.aws_s3_bucket_policy.react_policy
  to   = module.admin.aws_s3_bucket_policy.admin_bucket
}

# Creates a Cognito User Pool
module "pool" {
  source                 = "./modules/user_pool"
  control_domain         = var.control_domain
  bucket                 = module.bucket.bucket
  bucket_arn             = module.bucket.bucket_arn
  ecs_cluster_name       = module.ecs.cluster_name
  healthcheck_ping_param = local.hc_ping_assign_osid
  use_eum_sms            = var.use_eum_sms
  invitation_code        = var.invitation_code
}

# Creates an AWS Certificate Manager certificate for use on load balancers and CloudFront
module "cert" {
  source         = "./modules/cert"
  control_domain = var.control_domain
  zone_id        = data.terraform_remote_state.zone.outputs.control_domain_zone_id
}

# Public front door site at www.<control_domain>. Hosts the home page
# and the privacy/terms pages referenced by carrier registrations.
# See docs/front-door.md.
module "front_door" {
  source             = "./modules/front_door"
  control_domain     = var.control_domain
  zone_id            = data.terraform_remote_state.zone.outputs.control_domain_zone_id
  private_zone_id    = module.vpc.private_zone.zone_id
  cert_arn           = module.cert.cert_arn
  access_logs_bucket = module.s3_access_logs.bucket
}

# Sets up Route 53 hosted zones for mail domains. When the control domain is
# also a mail domain, its bootstrap zone is reused rather than duplicated.
# DNSSEC signing is opt-in per environment (var.dnssec_enabled); the
# control-domain zone's signing lives in the bootstrap dns stack.
module "domains" {
  source                 = "./modules/domains"
  mail_domains           = var.mail_domains
  control_domain         = var.control_domain
  control_domain_zone_id = data.terraform_remote_state.zone.outputs.control_domain_zone_id
  dnssec_enabled         = var.dnssec_enabled

  providers = {
    aws      = aws
    aws.use1 = aws.use1
  }
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
  bucket              = module.bucket.bucket
  bucket_arn          = module.bucket.bucket_arn
  bucket_domain_name  = module.bucket.domain_name
  oai_iam_arn         = module.bucket.oai_iam_arn
  relay_ips           = module.vpc.relay_ips
  dev_mode            = var.prod ? false : true

  address_changed_topic_arn = module.ecs.sns_topic_arn
  admin_group_name          = module.pool.admin_group_name

  dmarc_healthcheck_ping_param = local.hc_ping_dmarc

  invitation_required = module.pool.invitation_required
  monitoring          = var.monitoring
  imap_pool_enabled   = var.imap_pool_enabled
  access_logs_bucket  = module.s3_access_logs.bucket
}

# Creates a DynamoDB table for storing address data
module "table" {
  source = "./modules/table"
}

# Creates the VPC and network infrastructure
module "vpc" {
  source           = "./modules/vpc"
  use_nat_instance = var.use_nat_instance
  build_nat_ami    = var.build_nat_ami
  cidr_block       = var.cidr_block
  control_domain   = var.control_domain
  az_list          = var.availability_zones
  zone_id          = data.terraform_remote_state.zone.outputs.control_domain_zone_id
  quiesced         = var.quiesced
  region           = var.aws_region
}

# Creates a network load balancer shared by machines in the stack
module "load_balancer" {
  source            = "./modules/elb"
  public_subnet_ids = module.vpc.public_subnets[*].id
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

# Per-repo allow lists for the Phase 5 ECR pull-restriction policies
# (docs/0.10.x/identity-iam-hardening-plan.md). ARNs are reconstructed
# from the account ID here rather than read off module.ecs to avoid an
# ecr <-> ecs dependency cycle (the ecs module already consumes
# module.ecr.repository_urls). The names mirror the literals in
# modules/ecs/iam.tf: the mail tiers and sinkhole pull under the shared
# cabal-ecs-execution-role, with cabal-ecs-instance-role added because on
# the EC2 launch type the agent may authenticate the ECR pull with the
# container-instance role rather than the task execution role. The CI
# deploy role (var.deploy_role_arn) pushes images and runs the nightly
# scan; it is empty only in validate/destroy contexts, where dropping it
# is harmless.
#
# Monitoring repos are deliberately NOT covered here. Each one pulls
# under its own cabal-<tier>-execution role, which the monitoring module
# creates only when var.monitoring is true (off by default everywhere).
# ECR's SetRepositoryPolicy validates that named principals exist, so
# referencing those roles while monitoring is off fails the apply with
# "Principal not found"; and module.ecr is evaluated before
# module.monitoring, so the policy could not be ordered after the roles
# even when monitoring is on. A restriction for the monitoring repos
# therefore belongs in the monitoring module (where the per-tier roles
# are defined and correctly ordered); it is deferred while monitoring is
# a warm spare whose repos sit empty. The ecr module's repository-policy
# resource skips any repo absent from this map.
locals {
  ecr_account_id         = data.aws_caller_identity.current.account_id
  ecs_instance_role_arn  = "arn:aws:iam::${local.ecr_account_id}:role/cabal-ecs-instance-role"
  ecs_execution_role_arn = "arn:aws:iam::${local.ecr_account_id}:role/cabal-ecs-execution-role"
  ecr_deploy_pull_arns   = var.deploy_role_arn == "" ? [] : [var.deploy_role_arn]

  ecr_pull_principals_by_repo = {
    for tier in concat(local.core_mail_tiers, ["sinkhole"]) :
    tier => concat(
      [local.ecs_execution_role_arn, local.ecs_instance_role_arn],
      local.ecr_deploy_pull_arns,
    )
  }
}

# Creates ECR repositories for containerized mail services. Monitoring
# repos exist regardless of var.monitoring so the docker matrix can
# push images unconditionally; only the ECS services that consume them
# are gated by the flag. Phase 6 of the build/deploy simplification
# plan (docs/0.9.x/build-deploy-simplification-plan.md) routes them
# through monitoring_repositories so the underlying resource gets
# lifecycle { prevent_destroy = true } - toggling var.monitoring off
# (or trimming the docker matrix in app.yml) is now a no-op against
# the ECR repos rather than a destroy.
module "ecr" {
  source                      = "./modules/ecr"
  monitoring_repositories     = local.monitoring_tiers
  allowed_pull_principal_arns = local.ecr_pull_principals_by_repo
}

# ECS cluster, services, and task definitions for containerized mail tiers.
module "ecs" {
  source = "./modules/ecs"

  private_subnets = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc.id
  cidr_block      = var.cidr_block
  # The NLB lives in the public subnets and SNATs to its own ENIs
  # (preserve_client_ip is off for the ip/TCP target groups), so Dovecot sees
  # these CIDRs as the source of NLB-forwarded imap traffic. Phase 4.
  login_trusted_cidrs = module.vpc.public_subnets[*].cidr_block
  region              = var.aws_region
  control_domain      = var.control_domain

  table_arn = module.table.table_arn
  efs_id    = module.efs.efs_id

  smtp_queue_access_point_id = module.efs.smtp_queue_access_point_id

  user_pool_arn = module.pool.user_pool_arn
  user_pool_id  = module.pool.user_pool_id
  client_id     = module.pool.user_pool_client_id

  ecr_repository_urls = module.ecr.repository_urls
  image_tags = {
    for tier in concat(local.core_mail_tiers, ["sinkhole"]) :
    tier => local.tier_image_tags[tier]
  }

  # Health-check tuning - raise these to keep containers alive for debugging.
  # health_check_grace_period is consumed by the imap service only. 120s
  # comfortably covers image pull + entrypoint + Dovecot startup on a healthy
  # task; a task still failing NLB checks after that is a bad deploy, and the
  # imap deployment circuit breaker rolls it back instead of letting it
  # thrash (was 600, which gave a stuck task 10 minutes before ECS gave up).
  # Phase 2 of docs/0.10.x/imap-deploy-downtime-plan.md.
  health_check_grace_period = 120
  deregistration_delay      = 120
  unhealthy_threshold       = 10

  healthcheck_ping_param = local.hc_ping_ecs_reconfigure

  quiesced = var.quiesced

  sinkhole    = var.sinkhole
  environment = var.environment

  depends_on = [module.cert]
}

# Runs certbot on a schedule to renew Let's Encrypt certificates and restart ECS services
module "certbot_renewal" {
  source         = "./modules/certbot_renewal"
  control_domain = var.control_domain
  zone_id        = data.terraform_remote_state.zone.outputs.control_domain_zone_id
  email          = var.email
  region         = var.aws_region
  # Deliberately still the legacy global tag, not a per-tier key: the
  # certbot image follows the lambda_certbot area of app.yml (not the
  # docker matrix), and the Lambda ignores image_uri changes after
  # creation (see modules/certbot_renewal/lambda.tf), so this value is
  # only ever consumed at create time.
  image_tag        = data.aws_ssm_parameter.deployed_image_tag.value
  ecs_cluster_name = module.ecs.cluster_name
  ecs_service_names = [
    module.ecs.imap_service_name,
    module.ecs.smtp_in_service_name,
    module.ecs.smtp_out_service_name,
  ]

  healthcheck_ping_param = local.hc_ping_certbot
}

# Establishes a daily backup schedule for mail and address data. The
# vaults are lock-protected (governance mode) and every recovery point
# is copied to a second-region vault; see the module docstring and
# docs/disaster-recovery.md.
module "backup" {
  source = "./modules/backup"
  count  = var.backup ? 1 : 0
  table  = module.table.table_arn
  efs    = module.efs.efs_arn

  providers = {
    aws           = aws
    aws.dr_region = aws.dr_region
  }
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
  image_tags                             = { for tier in local.monitoring_tiers : tier => local.tier_image_tags[tier] }
  environment                            = var.environment

  user_pool_id     = module.pool.user_pool_id
  user_pool_arn    = module.pool.user_pool_arn
  user_pool_domain = module.pool.user_pool_domain

  lambda_bucket = module.bucket.bucket

  mail_domains                   = var.mail_domains
  healthchecks_registration_open = var.healthchecks_registration_open

  quiesced = var.quiesced
}
