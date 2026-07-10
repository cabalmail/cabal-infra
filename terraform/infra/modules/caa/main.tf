/**
* Publishes CAA records that authorize only the certificate authorities we
* actually use, so no other CA may issue a certificate for our domains.
*
* Both TLS certificates we issue target `*.<control_domain>`: the ACM
* certificate (`modules/cert`) and the Let's Encrypt certificate
* (`modules/certbot_renewal`). Because those are wildcards, every issuer is
* authorized for both `issue` and `issuewild`.
*
* - Control domain: ACM + Let's Encrypt. ACM rotates its issuing
*   intermediates by region and service, so all four Amazon CA identifiers are
*   authorized to avoid a surprise validation failure.
* - Mail domains: ACM only. Let's Encrypt is architecturally control-domain
*   only - certbot is hardwired to `CONTROL_DOMAIN` and the mail services
*   present control-domain hostnames, so a mail apex never terminates a
*   Let's Encrypt certificate. ACM stays authorized as the AWS-native path in
*   case a mail domain is ever fronted by an AWS service.
*
* A single CAA record at the control-domain apex governs every infrastructure
* subdomain: a CA validating `*.<control_domain>` climbs to that apex, finds
* the record, and stops. The control domain's record lives in the bootstrap
* `terraform/dns` zone but is written here (as `modules/cert` already does for
* ACM validation) to keep the "who may issue for us" policy in one place.
*/

locals {
  # ACM's issuing intermediates vary by region and service; authorize all four
  # Amazon identifiers. See https://docs.aws.amazon.com/acm/latest/userguide/setup-caa.html
  acm_issuers = ["amazon.com", "amazontrust.com", "awstrust.com", "amazonaws.com"]
  le_issuer   = "letsencrypt.org"

  # A CA that receives a request violating this policy can report it here.
  iodef_record = "0 iodef \"mailto:${var.iodef_email}\""

  # Control domain: ACM + Let's Encrypt, wildcard and non-wildcard.
  control_issuers = concat(local.acm_issuers, [local.le_issuer])
  control_records = concat(
    [for ca in local.control_issuers : "0 issue \"${ca}\""],
    [for ca in local.control_issuers : "0 issuewild \"${ca}\""],
    [local.iodef_record],
  )

  # Mail domains: ACM only.
  mail_records = concat(
    [for ca in local.acm_issuers : "0 issue \"${ca}\""],
    [for ca in local.acm_issuers : "0 issuewild \"${ca}\""],
    [local.iodef_record],
  )

  # Mail-domain zones that get their own CAA. The control domain is excluded:
  # its record is managed against the bootstrap zone below, and
  # `module.domains.domains` surfaces the control domain in this list when it
  # doubles as a mail domain (which would otherwise collide on the same zone
  # and name).
  mail_zones = {
    for d in var.mail_domains : d.domain => d.zone_id if d.domain != var.control_domain
  }
}

resource "aws_route53_record" "control" {
  zone_id = var.control_domain_zone_id
  name    = var.control_domain
  type    = "CAA"
  ttl     = var.ttl
  records = local.control_records
}

resource "aws_route53_record" "mail" {
  for_each = local.mail_zones

  zone_id = each.value
  name    = each.key
  type    = "CAA"
  ttl     = var.ttl
  records = local.mail_records
}
