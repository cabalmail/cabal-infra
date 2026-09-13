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
  zone_id = var.zone_id
  name    = "cabal._domainkey.${var.control_domain}"
  type    = "TXT"
  ttl     = "3600"
  records = [
    join("", [
      "v=DKIM1; k=rsa; p=",
      join("",
        slice(
          split(
            "\n", trimspace(
              tls_private_key.key.public_key_pem
            )
          ), 1, 4
        )
      ),
      "\" \"",
      join("",
        slice(
          split(
            "\n", trimspace(
              tls_private_key.key.public_key_pem
            )
          ), 4, 8
        )
      )
    ])
  ]
}

resource "aws_route53_record" "dmarc" {
  zone_id = var.zone_id
  name    = "_dmarc.${var.control_domain}"
  type    = "TXT"
  ttl     = "3600"
  records = [
    "v=DMARC1; p=reject; rua=mailto:dmarc-reports@mail-admin.${var.domains[0].domain}; ruf=mailto:dmarc-reports@mail-admin.${var.domains[0].domain}; fo=1; pct=100"
  ]
}

resource "aws_ssm_parameter" "dkim_private_key" {
  name        = "/cabal/dkim_private_key"
  description = "Private key for mail managed by ${var.control_domain}"
  type        = "SecureString"
  value       = tls_private_key.key.private_key_pem
}
# --- private-zone siblings for the mail-authentication records --------------
#
# The VPC private zone is named for the control domain, so inside the VPC it
# answers authoritatively for the whole name and the public zone's records are
# invisible. Same shadow, and the same remedy, as `admin_cname_private` in
# cloudfront.tf -- but these three matter to mail rather than to a probe.
#
# Every address subdomain's canonical record set (see
# `lambda/api/_shared/helper.py:address_dns_records`) points its mail
# authentication at a name under the control domain: SPF as
# `include:<control-domain>`, DKIM as a CNAME to `cabal._domainkey.<control
# -domain>`, DMARC as a CNAME to `_dmarc.<control-domain>`. OpenDMARC and the
# sendmail milters in the smtp-in task resolve those from inside the VPC, hit
# the private zone, and get NXDOMAIN. For DMARC that is measured: inbound mail
# claiming any mail subdomain -- or the control domain itself -- is stamped
# `dmarc=none (p=none dis=none)` while the published policy is `p=reject`
# (#1411), because policy discovery falls through to the organizational
# domain and is shadowed again there.
#
# `records` is taken from the public record rather than re-spelled, so the two
# cannot drift: one policy string, published in two zones.

resource "aws_route53_record" "spf_private" {
  zone_id = var.private_zone_id
  name    = var.control_domain
  type    = "TXT"
  ttl     = "360"
  records = aws_route53_record.spf.records
}

resource "aws_route53_record" "dkim_public_key_private" {
  zone_id = var.private_zone_id
  name    = "cabal._domainkey.${var.control_domain}"
  type    = "TXT"
  ttl     = "3600"
  records = aws_route53_record.dkim_public_key.records
}

resource "aws_route53_record" "dmarc_private" {
  zone_id = var.private_zone_id
  name    = "_dmarc.${var.control_domain}"
  type    = "TXT"
  ttl     = "3600"
  records = aws_route53_record.dmarc.records
}
