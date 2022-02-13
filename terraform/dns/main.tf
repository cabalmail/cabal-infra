/**
* # Cabalmail DNS
*
* The small Terraform stack in this directory stands up a Route53 Zone for the control domain of a Cabalmail system. In order for the main stack to run successfully, you must observe the output from this stack and [update your domain registration with the indicated nameservers](../../docs/registrar.md). See the [README.md](../../README.md) at the root of this repository for general information, and the [setup documentation](../../docs/setup.md) for specific steps.
*/

provider "aws" {
  region = var.aws_region
}

# Create the zone for the control domain.
resource "aws_route53_zone" "cabal_control_zone" {
  name          = var.control_domain
  comment       = "Control domain for cabal-mail infrastructure"
  force_destroy = true
  tags          = {
    Name                 = "cabal-control-zone"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

# Save the zone ID in AWS SSM Parameter Store so that terraform/infra can read it.
resource "aws_ssm_parameter" "zone" {
  name        = "/cabal/control_domain_zone_id"
  description = "Route 53 Zone ID"
  type        = "String"
  value       = aws_route53_zone.cabal_control_zone.zone_id

  tags = {
    environment          = "production"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
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

  tags = {
    environment          = "production"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

# S3 bucket for deploying React app
# TODO: update ARN od principle origin access identity  
resource "aws_s3_bucket" "react_app" {
  bucket = "admin.${var.control_domain}"
}

resource "aws_s3_bucket_website_configuration" "react_app_website" {
  bucket = aws_s3_bucket.react_app.id
  index_document = "index.html"
  error_document = "error.html"
}

resource "aws_s3_bucket_acl" "react_app_acl" {
  bucket = aws_s3_bucket.react_app.id
  acl    = "public-read"
}

resource "aws_s3_bucket_policy" "react_app_policy" {
  bucket = aws_s3_bucket.react_app.id
  policy = <<EOP
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Caesar",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity E1MCK388YJB8RY"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::admin.cabal-mail.net/*"
        },
        {
            "Sid": "AndNancy",
            "Effect": "Deny",
            "Principal": {
                "AWS": "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity E1MCK388YJB8RY"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::admin.cabal-mail.net/cabal.tar.gz"
        }
    ]
}
EOP
}

# Save bucket information in AWS SSM Parameter Store so that terraform/infra can read it.
resource "aws_ssm_parameter" "react_app" {
  name        = "/cabal/admin/bucket"
  description = "S3 bucket for React App"
  type        = "String"
  value       = jsonencode(aws_s3_bucket.react_app)

  tags = {
    environment          = "production"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

# Create Elastic Container Registry Repository
resource "aws_ecr_repository" "container_repo" {
  name = "cabal-registry"
}

# Save ECR information in AWS SSM Parameter Store so that terraform/infra can read it.
resource "aws_ssm_parameter" "container_repo" {
  name        = "/cabal/container/registry"
  description = "ECR repo"
  type        = "String"
  value       = jsonencode(aws_ecr_repository.container_repo)

  tags = {
    environment          = "production"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}
