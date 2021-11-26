resource "aws_route53_record" "cname" {
  for_each = toset( ["imap", "smtp-out", "smtp-in"] )
  zone_id  = var.zone_id
  name     = each.key
  type     = "A"

  alias {
    name                   = aws_lb.elb.dns_name
    zone_id                = aws_lb.elb.zone_id
    evaluate_target_health = false
  }
}