output "vpc" {
  value       = aws_vpc.network
  description = "VPC"
}

output "private_subnets" {
  value       = aws_subnet.private[*]
  description = "List of private subnets"
}

output "public_subnets" {
  value       = aws_subnet.public[*]
  description = "List of public subnets"
}

output "relay_ips" {
  value       = aws_eip.nat_eip[*].public_ip
  description = "List of egress IP addresses"
}
