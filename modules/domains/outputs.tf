output "domains" {
  value = [
    for k, v in aws_route53_zone.cabal_mail_zone : {
      "domain"  = k,
      "zone_id" = v.id
    }
  ]
}