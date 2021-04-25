provider "aws" {
  region = var.aws_primary_region
  alias  = "aws_primary"
}

provider "aws" {
  region = var.aws_secondary_region
  alias  = "aws_secondary"
}

module "cabal_control_zone" {
  source = "./modules/control-domain"
  name   = var.control_domain
  repo   = var.repo
}

module "cabal_certificate" {
  source = "./modules/cert"
  repo   = var.repo
  domain = var.control_domain
  sans   = []
  prod   = var.prod_cert
  email  = var.cert_email
}

module "cabal_primary_vpc" {
  source     = "./modules/vpc"
  cidr_block = var.primary_cidr_block
  az_list    = var.primary_availability_zones
  repo       = var.repo
  providers  = {
    aws = aws.aws_primary
  }
}

module "cabal_secondary_vpc" {
  # count      = var.create_secondary ? 1 : 0
  source     = "./modules/vpc"
  cidr_block = var.secondary_cidr_block
  az_list    = var.secondary_availability_zones
  repo       = var.repo
  providers  = {
    aws = aws.aws_secondary
  }
}

module "cabal_primary_load_balancer" {
  source         = "./modules/elb"
  public_subnets = module.cabal_primary_vpc.public_subnets
  vpc            = module.cabal_primary_vpc.vpc
  cert_key       = module.cabal_certificate.private_key
  cert_body      = module.cabal_certificate.cert
  cert_chain     = module.cabal_certificate.intermediate
  repo           = var.repo
  providers      = {
    aws = aws.aws_primary
  }
}

module "cabal_secondary_load_balancer" {
  count          = var.create_secondary ? 1 : 0
  source         = "./modules/elb"
  public_subnets = var.create_secondary ? module.cabal_secondary_vpc.public_subnets : []
  vpc            = var.create_secondary ? module.cabal_secondary_vpc.vpc : {}
  cert_key       = module.cabal_certificate.private_key
  cert_body      = module.cabal_certificate.cert
  cert_chain     = module.cabal_certificate.intermediate
  repo           = var.repo
  providers      = {
    aws = aws.aws_secondary
  }
}
