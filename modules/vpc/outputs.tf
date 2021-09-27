output "vpc" {
  value = aws_vpc.cabal_vpc
}

output "private_subnets" {
  value = aws_subnet.cabal_private_subnet[*]
}

output "public_subnets" {
  value = aws_subnet.cabal_public_subnet[*]
}

output "relay_ips" {
  value = aws_eip.cabal_nat_eip[*].public_ip
}