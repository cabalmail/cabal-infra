/**
* Creates Route 53 zones for all mail domains.
*
* When the control domain is also listed as a mail domain, its zone already
* exists (created by the bootstrap `terraform/dns` stack). We must NOT create a
* second hosted zone for the same name: duplicate Route 53 zones get distinct
* name servers, only one can be delegated at the registrar, and the other is
* silently blackholed. Instead we skip the control domain here and surface its
* pre-existing zone through the `domains` output, so address creation and the
* lambda DOMAINS map target the live, delegated zone.
*/

locals {
  control_is_mail_domain = contains(var.mail_domains, var.control_domain)
  # Mail domains that need a freshly created hosted zone: everything except the
  # control domain, whose zone is owned by the bootstrap stack.
  zone_domains = [for d in var.mail_domains : d if d != var.control_domain]
}

resource "aws_route53_zone" "mail_dns" {
  for_each      = toset(local.zone_domains)
  name          = each.key
  comment       = "Domain for ${each.value} mail"
  force_destroy = true
}

# Look up the existing control-domain zone (managed by terraform/dns) so the
# output can carry its real ARN and name servers without recreating it. Only
# instantiated when the control domain doubles as a mail domain.
data "aws_route53_zone" "control" {
  count   = local.control_is_mail_domain ? 1 : 0
  zone_id = var.control_domain_zone_id
}
