locals {
  created_domains = [
    for k, v in aws_route53_zone.mail_dns : {
      "domain"       = k,
      "zone_id"      = v.id
      "name_servers" = v.name_servers
      "arn"          = v.arn
    }
  ]

  # When the control domain doubles as a mail domain, surface its pre-existing
  # zone (looked up via data source) with the same shape. This is empty when the
  # control domain is not a mail domain (the data source has count 0). Appended
  # last so domains[0] remains the first dedicated mail domain for existing
  # deployments.
  control_domain_entry = [
    for z in data.aws_route53_zone.control : {
      "domain"       = var.control_domain,
      "zone_id"      = z.zone_id
      "name_servers" = z.name_servers
      "arn"          = z.arn
    }
  ]
}

output "domains" {
  value       = concat(local.created_domains, local.control_domain_entry)
  description = "List of maps with domains and their Route 53 zone IDs. Includes the control domain (reusing its bootstrap zone) when it is also a mail domain."
}

output "ds_records" {
  value       = { for domain, ksk in aws_route53_key_signing_key.mail : domain => ksk.ds_record }
  description = "Per-apex DS record values to publish at each domain registrar once signing is verified (sign first, DS second - see docs/dnssec.md). Empty until var.dnssec_enabled is true. Excludes the control domain, whose DS record is output by the bootstrap dns stack."
}
