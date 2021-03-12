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
  repo                = "https://github.com/ccarr-cabal/cabal-infra/tree/main"
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
  count      = var.az_count
  vpc_id     = aws_vpc.cabal_vpc.id
  cidr_block = local.private_cidr_blocks[count.index]
  tags       = {
    Name                 = "cabal-private-subnet-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_subnet" "cabal_public_subnet" {
  count      = var.az_count
  vpc_id     = aws_vpc.cabal_vpc.id
  cidr_block = local.public_cidr_blocks[count.index]
  tags       = {
    Name                 = "cabal-public-subnet-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_internet_gateway" "cabal_ig" {
  vpc_id   = aws_vpc.cabal_vpc.id
  tags     = {
    Name                 = "cabal-igw"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_eip" "cabal_nat_eip" {
  count      = var.az_count
  vpc        = true
  depends_on = [
    aws_internet_gateway.cabal_ig
  ]
  tags       = {
    Name                 = "cabal-nat-eip-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_nat_gateway" "cabal_nat" {
  count         = var.az_count
  allocation_id = aws_eip.cabal_nat_eip[count.index].id
  subnet_id     = aws_subnet.cabal_public_subnet[count.index].id
  tags          = {
    Name                 = "cabal-nat-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_route_table" "cabal_private_rt" {
  count      = var.az_count
  vpc_id     = aws_vpc.cabal_vpc.id
  tags       = {
    Name                 = "cabal-private-rt-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_route" "cabal_private_route" {
  count                  = var.az_count
  route_table_id         = aws_route_table.cabal_private_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.cabal_nat[count.index].id
}

resource "aws_route_table_association" "cabal_private_rta" {
  count          = var.az_count
  subnet_id      = aws_subnet.cabal_private_subnet[count.index].id
  route_table_id = aws_route_table.cabal_private_rt[count.index].id
}

resource "aws_route_table" "cabal_public_rt" {
  vpc_id   = aws_vpc.cabal_vpc.id
  tags     = {
    Name                 = "cabal-public-rt"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_route" "cabal_public_route" {
  route_table_id         = aws_route_table.cabal_public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.cabal_ig.id
}

resource "aws_route_table_association" "cabal_public_rta" {
  count          = var.az_count
  subnet_id      = aws_subnet.cabal_public_subnet[count.index].id
  route_table_id = aws_route_table.cabal_public_rt.id
}