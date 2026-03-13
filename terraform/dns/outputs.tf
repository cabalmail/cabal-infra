output "control_domain_zone_id" {
  value = aws_route53_zone.cabal_control_zone.zone_id
}

output "control_domain_zone_name" {
  value = var.control_domain
}

output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}
