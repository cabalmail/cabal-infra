provider "aws" {
  region = var.aws_region
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

# TODO
# Create EC2 instances with userdata:
# - SSM
# - yum install -y git
# - git clone https://... cookbook
# - install chef in local mode
# - run chef
# Create user pool
# Create DynamoDB Table
# Create lambda/api-gateway admin application
# Add some users
# Create chef environent
# Create chef roles
# Create autoscaling group configs
# Create autoscaling group