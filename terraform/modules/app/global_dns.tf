resource "aws_route53_record" "cabal_spf" {
  zone_id = var.zone_id
  name    = var.control_domain
  type    = "TXT"
  ttl     = "360"
  records = [
    "v=spf1 ${join(" ", [for ip in var.relay_ips : "ip4:${ip}/32"])} ~all"
  ]
}