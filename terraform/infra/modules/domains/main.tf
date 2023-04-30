/**
* Creates Route 53 zones for all mail domains.
*/

resource "aws_route53_zone" "mail_dns" {
  for_each      = toset(var.mail_domains)
  name          = each.key
  comment       = "Domain for ${each.value} mail"
  force_destroy = true
}

resource "tls_private_key" "key" {
  for_each  = toset(var.mail_domains)
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_route53_record" "dkim_public_key" {
  for_each  = toset(var.mail_domains)
  zone_id   = var.zone_id
  name      = "cabal._dmainkey.${each.key}"
  type      = "CNAME"
  ttl       = "3600"
  records   = [
    join("", [
      "v=DKIM1; k=rsa; p=",
      join("",
        slice(
          split(
            "\n",trimspace(
              tls_private_key.key[each.key].public_key_pem
            )
          ), 1, 3
        )
      )
    ]),
    join("",
      slice(
        split(
          "\n",trimspace(
            tls_private_key.key[each.key].public_key_pem
          )
        ), 4, 7
      )
    )
  ]
}

resource "aws_ssm_parameter" "dkim_private_key" {
  for_each    = toset(var.mail_domains)
  name        = "/cabal/dkim_private_key/${each.key}"
  description = "Private key for mail in the ${each.key} domain"
  type        = "SecureString"
  value       = tls_private_key.key[each.key].private_key_pem
}