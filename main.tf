provider "aws" {
  region       = var.aws_region
  default_tags = {
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

module "cabal_vpc" {
  source     = "./modules/vpc"
  cidr_block = var.cidr_block
  az_list    = var.availability_zones
  repo       = var.repo
}

module "cabal_load_balancer" {
  source         = "./modules/elb"
  public_subnets = module.cabal_vpc.public_subnets
  vpc            = module.cabal_vpc.vpc
  repo           = var.repo
  control_domain = var.control_domain
  zone_id        = var.zone_id
}

module "cabal_efs" {
  source         = "./modules/efs"
  repo           = var.repo
}

module "cabal_imap" {
  source          = "./modules/imap"
  private_subnets = module.cabal_vpc.private_subnets
  repo            = var.repo
}

# TODO
# Create SMTP
# Create user pool
# Create DynamoDB Table
# Create lambda/api-gateway admin application
# Add some users
# Create chef environent
# Create chef roles
# Create autoscaling group configs
# Create autoscaling group