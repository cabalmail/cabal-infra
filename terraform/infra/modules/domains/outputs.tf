output "domains" {
  value       = [
    for k, v in aws_route53_zone.mail_dns : {
      "domain"       = k,
      "zone_id"      = v.id
      "name_servers" = v.name_servers
      "arn"          = v.arn
    }
  ]
  description = "List of maps with domains and their Route 53 zone IDs."
}