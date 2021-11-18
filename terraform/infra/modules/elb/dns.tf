resource "aws_route53_record" "cabal_cname" {
  for_each = toset( ["imap", "smtp-out", "smtp-in"] )
  zone_id  = var.zone_id
  name     = each.key
  type     = "A"

  alias {
    name                   = aws_lb.cabal_nlb.dns_name
    zone_id                = aws_lb.cabal_nlb.zone_id
    evaluate_target_health = false
  }
}