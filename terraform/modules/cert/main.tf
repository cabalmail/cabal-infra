resource "aws_acm_certificate" "cabal_elb_cert" {
  domain_name       = "*.${var.control_domain}"
  validation_method = "DNS"
  tags              = {
    Name                 = "cabal-nlb"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cabal_elb_cert_dns" {
  for_each = {
    for dvo in aws_acm_certificate.cabal_elb_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.zone_id
}

resource "aws_acm_certificate_validation" "cabal_elb_cert_validation" {
  certificate_arn         = aws_acm_certificate.cabal_elb_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cabal_elb_cert_dns : record.fqdn]
}