resource "aws_internet_gateway" "cabal_ig" {
  vpc_id   = aws_vpc.cabal_vpc.id
  tags     = {
    Name = "cabal-igw"
  }
}

resource "aws_eip" "cabal_nat_eip" {
  count      = length(var.az_list)
  vpc        = true
  depends_on = [
    aws_internet_gateway.cabal_ig
  ]
  tags       = {
    Name = "cabal-nat-eip-${count.index}"
  }
}

resource "aws_route53_record" "cabal_smtp" {
  zone_id = var.zone_id
  name    = "smtp.${var.control_domain}"
  type    = "A"
  ttl     = 360
  records = aws_eip.cabal_nat_eip[*].public_ip
}