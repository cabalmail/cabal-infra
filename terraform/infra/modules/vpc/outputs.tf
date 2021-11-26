output "vpc" {
  value = aws_vpc.network
}

output "private_subnets" {
  value = aws_subnet.private[*]
}

output "public_subnets" {
  value = aws_subnet.public[*]
}

output "relay_ips" {
  value = aws_eip.nat_eip[*].public_ip
}

output "private_zone" {
  value = aws_route53_zone.private_dns
}