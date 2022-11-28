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

# Creates a Cognito User Pool
module "pool" {
  source         = "./modules/user_pool"
  control_domain = var.control_domain
  zone_id        = aws_route53_zone.cabal_control_zone.zone_id
}

# Save Cognito user pool information in AWS SSM Parameter Store so that terraform/infra can read it.
resource "aws_ssm_parameter" "cognito" {
  name        = "/cabal/admin/cognito"
  description = "Cognito User Pool"
  type        = "String"
  value       = jsonencode(module.pool)
}

# Create S3 bucket for React App
module "bucket" {
  source         = "./modules/s3"
  control_domain = var.control_domain
}