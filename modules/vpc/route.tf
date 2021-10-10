resource "aws_route_table" "cabal_private_rt" {
  count      = length(var.az_list)
  vpc_id     = aws_vpc.cabal_vpc.id
  tags       = {
    Name = "cabal-private-rt-${count.index}"
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
    Name = "cabal-public-rt"
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