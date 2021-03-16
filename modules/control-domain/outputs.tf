output "zone_id" {
  value = aws_route53_zone.cabal_control_zone.zone_id
}

output "name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}