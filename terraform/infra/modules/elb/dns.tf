resource "aws_route53_record" "cname" {
  for_each = toset(["imap", "smtp-out", "smtp-in"])
  zone_id  = var.zone_id
  name     = each.key
  type     = "A"

  alias {
    name                   = aws_lb.elb.dns_name
    zone_id                = aws_lb.elb.zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "srv" {
  for_each = {
    "_submission._tcp" = {
      port = 587
      host = "smtp-out.${var.control_domain}"
    },
    "_imaps._tcp" = {
      port = 993
      host = "imap.${var.control_domain}"
    },
    "_imap._tcp" = {
      port = 0
      host = "."
    },
    "_pop3._tcp" = {
      port = 0
      host = "."
    },
    "_pop3s._tcp" = {
      port = 0
      host = "."
    }
  }
  zone_id = var.zone_id
  name    = each.key
  type    = "SRV"
  ttl     = 3600
  records = [
    "0 1 ${each.value.port} ${each.value.host}"
  ]
}