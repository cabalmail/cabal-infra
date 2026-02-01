resource "aws_subnet" "private" {
  count             = length(var.az_list)
  vpc_id            = aws_vpc.network.id
  availability_zone = var.az_list[count.index]
  cidr_block        = cidrsubnet(var.cidr_block, local.bit_offset, count.index)
  tags = {
    Name = "cabal-private-subnet-${count.index}"
  }
}

resource "aws_subnet" "public" {
  count             = length(var.az_list)
  vpc_id            = aws_vpc.network.id
  availability_zone = var.az_list[count.index]
  cidr_block        = cidrsubnet(var.cidr_block, local.bit_offset, length(var.az_list) + count.index)
  tags = {
    Name = "cabal-public-subnet-${count.index}"
  }
}