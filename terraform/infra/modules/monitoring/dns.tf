resource "aws_route53_record" "uptime" {
  zone_id = var.zone_id
  name    = "uptime.${var.control_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.uptime.dns_name
    zone_id                = aws_lb.uptime.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "ntfy" {
  zone_id = var.zone_id
  name    = "ntfy.${var.control_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.uptime.dns_name
    zone_id                = aws_lb.uptime.zone_id
    evaluate_target_health = true
  }
}

# Mirror uptime/ntfy aliases into the VPC's private zone so Kuma probes
# from the private subnet can resolve them. The private zone shadows
# the public zone for the control domain, so without these records,
# VPC-internal lookups for uptime/ntfy fail.
resource "aws_route53_record" "uptime_private" {
  zone_id = var.private_zone_id
  name    = "uptime.${var.control_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.uptime.dns_name
    zone_id                = aws_lb.uptime.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "ntfy_private" {
  zone_id = var.private_zone_id
  name    = "ntfy.${var.control_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.uptime.dns_name
    zone_id                = aws_lb.uptime.zone_id
    evaluate_target_health = true
  }
}
