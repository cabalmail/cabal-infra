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
