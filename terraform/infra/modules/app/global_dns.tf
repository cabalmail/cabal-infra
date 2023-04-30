resource "aws_route53_record" "spf" {
  zone_id = var.zone_id
  name    = var.control_domain
  type    = "TXT"
  ttl     = "360"
  records = [
    "v=spf1 ${join(" ", [for ip in var.relay_ips : "ip4:${ip}/32"])} ~all"
  ]
}

resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_route53_record" "dkim_public_key" {
  zone_id   = var.zone_id
  name      = "cabal._domainkey.${var.control_domain}"
  type      = "TXT"
  ttl       = "3600"
  records   = [
    join("", [
      "v=DKIM1; k=rsa; p=",
      join("",
        slice(
          split(
            "\n",trimspace(
              tls_private_key.key.public_key_pem
            )
          ), 1, 3
        )
      ),
      "\" \"",
      join("",
        slice(
          split(
            "\n",trimspace(
              tls_private_key.key.public_key_pem
            )
          ), 4, 7
        )
      )
    ])
  ]
}

resource "aws_route53_record" "dmarc" {
  zone_id   = var.zone_id
  name      = "cabal._domainkey.${var.control_domain}"
  type      = "TXT"
  ttl       = "3600"
  records   = [
    "v=DMARC1; p=reject; rua=mailto:dmarc-reports@mail-admin.cabalmail.com; ruf=mailto:dmarc-reports@mail-admin.cabalmail.com; fo=1; pct=100"
  ]
}

# SPF is defined in /infra/modules/app/global_dns.tf

resource "aws_ssm_parameter" "dkim_private_key" {
  name        = "/cabal/dkim_private_key"
  description = "Private key for mail managed by ${var.control_domain}"
  type        = "SecureString"
  value       = tls_private_key.key.private_key_pem
}