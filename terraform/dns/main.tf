/**
* # Cabalmail DNS
*
* The small Terraform stack in this directory stands up a Route53 Zone for the control domain of a Cabalmail system. In order for the main stack to run successfully, you must observe the output from this stack and [update your domain registration with the indicated nameservers](../../docs/registrar.md). See the [README.md](../../README.md) at the root of this repository for general information, and the [setup documentation](../../docs/setup.md) for specific steps.
*/

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      environment          = var.prod ? "production" : "non-production"
      managed_by_terraform = "y"
      terraform_repo       = var.repo
    }
  }
}

# Create the zone for the control domain.
resource "aws_route53_zone" "cabal_control_zone" {
  name          = var.control_domain
  comment       = "Control domain for cabal-mail infrastructure"
  force_destroy = true
  tags          = {
    Name = "cabal-control-zone"
  }
}

# Save the zone ID in AWS SSM Parameter Store so that terraform/infra can read it.
resource "aws_ssm_parameter" "zone" {
  name        = "/cabal/control_domain_zone_id"
  description = "Route 53 Zone ID"
  type        = "String"
  value       = aws_route53_zone.cabal_control_zone.zone_id
}

# Save the zone name in AWS SSM Parameter Store so that terraform/infra can read it.
resource "aws_ssm_parameter" "name" {
  name        = "/cabal/control_domain_zone_name"
  description = "Route 53 Zone Name"
  type        = "String"
  value       = var.control_domain
}

# S3 bucket for hosting React app
resource "aws_s3_bucket" "this" {
  bucket = "admin.${var.control_domain}"
}

# These objects must exist for the next stage to run without error. It will
# get replaced with correct hash content by the Lambda Counter Github actions.
resource "aws_s3_object" "seed_hashes" {
  for_each = toset(local.lambdas)
  key      = "/lambda/${each.key}.zip.base64sha256"
  bucket   = aws_s3_bucket.this.bucket
  content  = "check-meets-egg"
}
resource "aws_s3_object" "seed_zips" {
  for_each = toset(local.lambdas)
  key      = "/lambda/${each.key}.zip"
  bucket   = aws_s3_bucket.this.bucket
  content  = "check-meets-egg"
}

# Trigger builds.
# Data source is ignored, but triggers Github actions as a side-effect.
data "http" "trigger_builds" {
  url          = "https://api.github.com/repos/cabalmail/cabal-infra/dispatches"
  method       = "POST"
  request_headers = {
    Accept               = "application/vnd.github+json"
    Authorization        = "Bearer ${var.github_token}"
    X-GitHub-Api-Version = "2022-11-28"
  }
  request_body = <<EO_BODY
{
  "event_type": "trigger_build_${var.prod ? "prod" : "stage"}",
  "client_payload": {
    "bucket_name": "${resource.aws_s3_bucket.this.bucket}",
    "ref":"${var.prod ? "main" : "stage"}"
  }
}
EO_BODY
}