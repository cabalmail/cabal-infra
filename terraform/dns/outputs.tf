output "control_domain_zone_id" {
  value = aws_route53_zone.cabal_control_zone.zone_id
}

output "control_domain_zone_name" {
  value = var.control_domain
}

output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}

# Null until var.dnssec_enabled is true. Once signing is verified, the
# operator copies this DS record to the domain registrar to establish
# the chain of trust - sign first, DS second. See docs/dnssec.md.
output "control_domain_ds_record" {
  value = one(aws_route53_key_signing_key.control[*].ds_record)
}
