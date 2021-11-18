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