locals {
  private_cidr_blocks = [
    cidrsubnet(var.cidr_block, 4, 0),
    cidrsubnet(var.cidr_block, 4, 1),
    cidrsubnet(var.cidr_block, 4, 2),
  ]
  public_cidr_blocks  = [
    cidrsubnet(var.cidr_block, 4, 4),
    cidrsubnet(var.cidr_block, 4, 5),
    cidrsubnet(var.cidr_block, 4, 6),
  ]
  repo = "https://github.com/ccarr-cabal/cabal-infra/tree/main"
}

resource "aws_vpc" "cabal_vpc" {
  cidr_block = var.cidr_block
  tags       = {
    Name                 = "cabal-vpc"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_subnet" "cabal_private_subnet" {
  count  = 3
  vpc_id = aws_vpc.cabal_vpc.id
  cidr_block = local.private_cidr_blocks[count.index]
  tags       = {
    Name                 = "cabal-private-subnet-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_subnet" "cabal_public_subnet" {
  count  = 3
  vpc_id = aws_vpc.cabal_vpc.id
  cidr_block = local.public_cidr_blocks[count.index]
  tags       = {
    Name                 = "cabal-public-subnet-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}
