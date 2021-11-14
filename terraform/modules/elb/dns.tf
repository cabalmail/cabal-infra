resource "aws_route53_record" "cabal_imap_cname" {
  zone_id = var.zone_id
  name    = "imap"
  type    = "A"

  alias {
    name                   = aws_lb.cabal_nlb.dns_name
    zone_id                = aws_lb.cabal_nlb.zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "cabal_smtpout_cname" {
  zone_id = var.zone_id
  name    = "smtp-out"
  type    = "A"

  alias {
    name                   = aws_lb.cabal_nlb.dns_name
    zone_id                = aws_lb.cabal_nlb.zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "cabal_smtpin_cname" {
  zone_id = var.zone_id
  name    = "smtp-in"
  type    = "A"

  alias {
    name                   = aws_lb.cabal_nlb.dns_name
    zone_id                = aws_lb.cabal_nlb.zone_id
    evaluate_target_health = false
  }
}