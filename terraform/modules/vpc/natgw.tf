resource "aws_nat_gateway" "cabal_nat" {
  count         = length(var.az_list)
  allocation_id = aws_eip.cabal_nat_eip[count.index].id
  subnet_id     = aws_subnet.cabal_public_subnet[count.index].id
  tags          = {
    Name = "cabal-nat-${count.index}"
  }
}