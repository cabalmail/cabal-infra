provider "aws" {
  region = var.aws_region
}

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