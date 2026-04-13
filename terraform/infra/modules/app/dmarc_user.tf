# System user for receiving DMARC aggregate reports.
# The process_dmarc Lambda accesses this mailbox via the master-user IMAP pattern.

resource "random_password" "dmarc_password" {
  length           = 16
  special          = true
  override_special = "()-_=+[]<>:"
}

resource "aws_cognito_user" "dmarc" {
  user_pool_id = var.user_pool_id
  username     = "dmarc"
  enabled      = true
  password     = random_password.dmarc_password.result
  attributes = {
    osid = 9998
  }
}

# Address record so mail to dmarc-reports@mail-admin.<domain> is delivered to the dmarc user.
resource "aws_dynamodb_table_item" "dmarc_address" {
  table_name = "cabal-addresses"
  hash_key   = "address"
  item       = jsonencode({
    address   = { S = "dmarc-reports@mail-admin.${var.domains[0].domain}" }
    tld       = { S = var.domains[0].domain }
    user      = { S = "dmarc" }
    username  = { S = "dmarc-reports" }
    subdomain = { S = "mail-admin" }
    "zone-id" = { S = var.domains[0].zone_id }
    comment   = { S = "System address for DMARC aggregate reports" }
  })

  depends_on = [aws_cognito_user.dmarc]
}

# DNS records for the mail-admin subdomain on the first mail domain.
# If these already exist from a previously created address, import them:
#   terraform import 'module.admin.aws_route53_record.dmarc_subdomain_mx' <zone_id>_mail-admin.<domain>_MX

resource "aws_route53_record" "dmarc_subdomain_mx" {
  zone_id = var.domains[0].zone_id
  name    = "mail-admin.${var.domains[0].domain}"
  type    = "MX"
  ttl     = 3600
  records = ["10 smtp-in.${var.control_domain}"]

  lifecycle {
    ignore_changes = [records]
  }
}

resource "aws_route53_record" "dmarc_subdomain_spf" {
  zone_id = var.domains[0].zone_id
  name    = "mail-admin.${var.domains[0].domain}"
  type    = "TXT"
  ttl     = 3600
  records = ["v=spf1 include:${var.control_domain} ~all"]

  lifecycle {
    ignore_changes = [records]
  }
}

resource "aws_route53_record" "dmarc_subdomain_dkim" {
  zone_id = var.domains[0].zone_id
  name    = "cabal._domainkey.mail-admin.${var.domains[0].domain}"
  type    = "CNAME"
  ttl     = 3600
  records = ["cabal._domainkey.${var.control_domain}"]

  lifecycle {
    ignore_changes = [records]
  }
}

resource "aws_route53_record" "dmarc_subdomain_dmarc" {
  zone_id = var.domains[0].zone_id
  name    = "_dmarc.mail-admin.${var.domains[0].domain}"
  type    = "CNAME"
  ttl     = 3600
  records = ["_dmarc.${var.control_domain}"]

  lifecycle {
    ignore_changes = [records]
  }
}
