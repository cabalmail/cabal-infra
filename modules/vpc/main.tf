locals {
  bit_offsets = [ 0,1,2,2,3,3,3,3,4,4,4,4,4,4,4,4 ]
  bit_offset  = local.bit_offsets[length(var.az_list)*2]
}

resource "aws_vpc" "cabal_vpc" {
  cidr_block = var.cidr_block
  tags       = {
    Name                 = "cabal-vpc"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

resource "aws_subnet" "cabal_private_subnet" {
  count             = length(var.az_list)
  vpc_id            = aws_vpc.cabal_vpc.id
  availability_zone = var.az_list[count.index]
  cidr_block        = cidrsubnet(var.cidr_block, local.bit_offset, count.index)
  tags              = {
    Name                 = "cabal-private-subnet-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

resource "aws_subnet" "cabal_public_subnet" {
  count             = length(var.az_list)
  vpc_id            = aws_vpc.cabal_vpc.id
  availability_zone = var.az_list[count.index]
  cidr_block        = cidrsubnet(var.cidr_block, local.bit_offset, length(var.az_list) + count.index)
  tags              = {
    Name                 = "cabal-public-subnet-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

resource "aws_internet_gateway" "cabal_ig" {
  vpc_id   = aws_vpc.cabal_vpc.id
  tags     = {
    Name                 = "cabal-igw"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

resource "aws_eip" "cabal_nat_eip" {
  count      = length(var.az_list)
  vpc        = true
  depends_on = [
    aws_internet_gateway.cabal_ig
  ]
  tags       = {
    Name                 = "cabal-nat-eip-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

resource "aws_nat_gateway" "cabal_nat" {
  count         = length(var.az_list)
  allocation_id = aws_eip.cabal_nat_eip[count.index].id
  subnet_id     = aws_subnet.cabal_public_subnet[count.index].id
  tags          = {
    Name                 = "cabal-nat-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

resource "aws_route_table" "cabal_private_rt" {
  count      = length(var.az_list)
  vpc_id     = aws_vpc.cabal_vpc.id
  tags       = {
    Name                 = "cabal-private-rt-${count.index}"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

resource "aws_route" "cabal_private_route" {
  count                  = length(var.az_list)
  route_table_id         = aws_route_table.cabal_private_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.cabal_nat[count.index].id
}

resource "aws_route_table_association" "cabal_private_rta" {
  count          = length(var.az_list)
  subnet_id      = aws_subnet.cabal_private_subnet[count.index].id
  route_table_id = aws_route_table.cabal_private_rt[count.index].id
}

resource "aws_route_table" "cabal_public_rt" {
  vpc_id   = aws_vpc.cabal_vpc.id
  tags     = {
    Name                 = "cabal-public-rt"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

resource "aws_route" "cabal_public_route" {
  route_table_id         = aws_route_table.cabal_public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.cabal_ig.id
}

resource "aws_route_table_association" "cabal_public_rta" {
  count          = length(var.az_list)
  subnet_id      = aws_subnet.cabal_public_subnet[count.index].id
  route_table_id = aws_route_table.cabal_public_rt.id
}