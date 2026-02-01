resource "aws_route_table" "private" {
  count  = length(var.az_list)
  vpc_id = aws_vpc.network.id
  tags = {
    Name = "cabal-private-rt-${count.index}"
  }
}

resource "aws_route" "private" {
  count                  = length(var.az_list)
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.use_nat_instance ? null : aws_nat_gateway.nat[count.index].id
  network_interface_id   = var.use_nat_instance ? aws_instance.nat[count.index].primary_network_interface_id : null
}

resource "aws_route_table_association" "private" {
  count          = length(var.az_list)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.network.id
  tags = {
    Name = "cabal-public-rt"
  }
}

resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ig.id
}

resource "aws_route_table_association" "public" {
  count          = length(var.az_list)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}