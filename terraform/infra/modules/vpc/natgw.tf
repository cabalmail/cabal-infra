resource "aws_internet_gateway" "ig" {
  vpc_id   = aws_vpc.network.id
  tags     = {
    Name = "cabal-igw"
  }
}

resource "aws_nat_gateway" "nat" {
  count         = length(var.az_list)
  allocation_id = aws_eip.nat_eip[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = {
    Name = "cabal-nat-${count.index}"
  }
}

resource "aws_eip" "nat_eip" {
  count      = length(var.az_list)
  vpc        = true
  depends_on = [
    aws_internet_gateway.ig
  ]
  tags       = {
    Name = "cabal-nat-eip-${count.index}"
  }
}

resource "aws_route53_record" "smtp" {
  zone_id = var.zone_id
  name    = "smtp.${var.control_domain}"
  type    = "A"
  ttl     = 360
  records = aws_eip.nat_eip[*].public_ip
}

# No native way to do this in the aws terraform provider
resource "null_resource" "create-endpoint" {
  count = length(aws_eip.nat_eip)
  triggers = {
    ip_addresses = join(",", aws_eip.nat_eip.*.public_ip)
    domain_name  = "smtp.${var.control_domain}"
  }
  provisioner "local-exec" {
    command = join(" ", [
      "aws ec2 modify-address-attribute",
      "--allocation-id ${aws_nat_gateway.nat[count.index].allocation_id}",
      "--domain-name smtp.${var.control_domain}"
    ])
  }
  provisioner "local-exec" {
    when    = destroy
    command = join(" ", [
      "aws ec2 modify-address-attribute",
      "--allocation-id ${aws_nat_gateway.nat[count.index].allocation_id}",
      "--domain-name ''"
    ])
  }
}
