/**
* Creates Route 53 zones for all mail domains.
*/

resource "aws_route53_zone" "mail_dns" {
  for_each      = toset(var.mail_domains)
  name          = each.key
  comment       = "Domain for ${each.value} mail"
  force_destroy = true
}

resource "aws_route53_record" "a" {
  for_each = toset(var.mail_domains[each.key])
  name     = "*.${each.key}"
  type     = "A"
  zone_id  = aws_route53_zone.mail_dns.id
  records  = ["127.0.0.1"]
}
