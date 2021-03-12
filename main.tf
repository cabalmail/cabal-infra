provider "aws" {
  region = var.aws_region
}

module "cabal_vpc" {
  source     = "./modules/vpc"
  cidr_block = var.cidr_block
  az_count   = var.az_count
  provider   = provider.aws
}