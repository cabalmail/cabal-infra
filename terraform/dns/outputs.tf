output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}
