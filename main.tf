provider "aws" {
  region = var.aws_primary_region
  alias  = "aws_primary"
}

provider "aws" {
  region = var.aws_secondary_region
  alias  = "aws_secondary"
}

module "cabal_primary_vpc" {
  source     = "./modules/vpc"
  cidr_block = var.primary_cidr_block
  az_count   = var.az_count
  providers  = {
    aws = aws.aws_primary
  }
}

module "cabal_secondary_vpc" {
  count      = var.create_secondary ? 1 : 0
  source     = "./modules/vpc"
  cidr_block = var.secondary_cidr_block
  az_count   = var.az_count
  providers  = {
    aws = aws.aws_secondary
  }
}

module "cabal_primary_load_balancer" {
  source          = "./modules/elb"
  private_subnets = module.cabal_primary_vpc.private_subnets
  vpc             = module.cabal_primary_vpc.vpc
  providers       = {
    aws = aws.aws_primary
  }
}

module "cabal_secondary_load_balancer" {
  count           = var.create_secondary ? 1 : 0
  source          = "./modules/elb"
  private_subnets = module.cabal_secondary_vpc.private_subnets
  vpc             = module.cabal_secondary_vpc.vpc
  providers       = {
    aws = aws.aws_secondary
  }
}
