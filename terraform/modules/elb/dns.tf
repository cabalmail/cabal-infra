resource "aws_route53_record" "cabal_imap_cname" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "imap"
  type    = "CNAME"
  ttl     = "900"

  records        = [aws_lb.cabal_nlb.dns_name]
}

resource "aws_route53_record" "cabal_smtpout_cname" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "smtp-out"
  type    = "CNAME"
  ttl     = "900"

  records        = [aws_lb.cabal_nlb.dns_name]
}

resource "aws_route53_record" "cabal_smtpin_cname" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "smtp-in"
  type    = "CNAME"
  ttl     = "900"

  records        = [aws_lb.cabal_nlb.dns_name]
}