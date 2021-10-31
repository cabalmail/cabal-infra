resource "aws_route53_zone" "cabal_mail_zone" {
  for_each      = toset(var.mail_domains)
  name          = each.key
  comment       = "Domain for ${each.value} mail"
  force_destroy = true
}