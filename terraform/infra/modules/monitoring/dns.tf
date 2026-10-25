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

resource "aws_route53_record" "heartbeat" {
  zone_id = var.zone_id
  name    = "heartbeat.${var.control_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.uptime.dns_name
    zone_id                = aws_lb.uptime.zone_id
    evaluate_target_health = true
  }
}

# These names are published once, in the public zone. Kuma probes run from the
# private subnet and resolve them there: the VPC used to hold a Route 53
# private zone named for the control domain, which shadowed the public zone
# for every name below it and so needed a mirror of each of these, but that
# zone is gone (#2064).

# Phase 3: Grafana at metrics.<control-domain>.
resource "aws_route53_record" "metrics" {
  zone_id = var.zone_id
  name    = "metrics.${var.control_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.uptime.dns_name
    zone_id                = aws_lb.uptime.zone_id
    evaluate_target_health = true
  }
}
