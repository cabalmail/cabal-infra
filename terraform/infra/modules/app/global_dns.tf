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

# --- no private-zone siblings ------------------------------------------------
#
# The apex SPF, cabal._domainkey and _dmarc records above used to be published
# twice: once here and once into a Route 53 private zone named for the control
# domain, because that zone was authoritative inside the VPC for every name
# below it and the public copies were invisible there (#1411). OpenDKIM and
# OpenDMARC in the smtp-in task read these names from inside the VPC.
#
# That private zone is gone (#2064) - it shadowed every address subdomain of
# the control domain too, which 553-rejected any inbound message whose sender
# was one of those addresses. With no zone in the way these records answer in
# the VPC exactly as they answer on the internet, so the mirrors are retired
# rather than rehomed.
