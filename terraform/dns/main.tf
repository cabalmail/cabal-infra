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

# S3 bucket for deploying React app
resource "aws_s3_bucket" "react_app" {
  bucket = "admin.${var.control_domain}"
}

resource "aws_s3_bucket_website_configuration" "react_app_website" {
  bucket = aws_s3_bucket.react_app.id
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_acl" "react_app_acl" {
  bucket = aws_s3_bucket.react_app.id
  acl    = "private"
}

resource "aws_cloudfront_origin_access_identity" "origin" {
  comment = "Static admin website"
}

data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.react_app.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.origin.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "react_policy" {
  bucket = aws_s3_bucket.react_app.id
  policy = data.aws_iam_policy_document.s3_policy.json
}

resource "aws_s3_bucket_public_access_block" "react_access" {
  bucket = aws_s3_bucket.react_app.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Save bucket information in AWS SSM Parameter Store so that terraform/infra can read it.
resource "aws_ssm_parameter" "react_app" {
  name        = "/cabal/admin/bucket"
  description = "S3 bucket for React App"
  type        = "String"
  value       = jsonencode(aws_s3_bucket.react_app)
}
resource "aws_ssm_parameter" "bucket_name" {
  name        = "/cabal/react-config/s3-bucket"
  description = "S3 bucket for React App deployment"
  type        = "String"
  value       = aws_s3_bucket.react_app.id
}
resource "aws_ssm_parameter" "origin_id" {
  name        = "/cabal/react-config/origin-id"
  description = "S3 bucket for React App deployment"
  type        = "String"
  value       = aws_cloudfront_origin_access_identity.origin.id
}

# Create Elastic Container Registry Repository
#tfsec:ignore:aws-ecr-repository-customer-key
resource "aws_ecr_repository" "container_repo" {
  name                 = "cabal-registry"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

# Save ECR information in AWS SSM Parameter Store so that terraform/infra can read it.
resource "aws_ssm_parameter" "container_repo" {
  name        = "/cabal/container/registry"
  description = "ECR repo"
  type        = "String"
  value       = jsonencode(aws_ecr_repository.container_repo)
}
