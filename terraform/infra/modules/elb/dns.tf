resource "aws_route53_record" "cname" {
  for_each = toset(["imap", "smtp-out", "smtp-in"])
  zone_id  = var.zone_id
  name     = each.key
  type     = "A"

  alias {
    name                   = aws_lb.elb.dns_name
    zone_id                = aws_lb.elb.zone_id
    evaluate_target_health = false
  }
}

# -- Private zone records ----------------------------------------
#
# The VPC has a private Route 53 zone for the control domain.
# When a query for e.g. imap.<control_domain> originates inside the
# VPC, Route 53 Resolver checks the private zone first and returns
# NXDOMAIN if the record is missing - it never falls through to the
# public zone.  These records mirror the public aliases above so
# that containers (and anything else in the VPC) can resolve the
# tier hostnames.

resource "aws_route53_record" "private" {
  # imap is included so internal probes (blackbox-exporter's blackbox-tls
  # job hits imap.<control_domain>:993 from inside the VPC to populate
  # probe_ssl_earliest_cert_expiry, which feeds the Mail Tiers dashboard's
  # "TLS days to expiry - IMAP 993" panel and BlackboxTLSCertExpiringSoon
  # alert) can resolve the hostname to the NLB and reach the TLS listener.
  #
  # Container-to-container IMAP delivery (smtp-out -> imap LMTP/SMTP) still
  # uses Cloud Map's imap.cabal.internal, which routes directly to the
  # container's private IP on port 143 and bypasses the NLB. See
  # modules/ecs/service_discovery.tf.
  #
  # The theoretical concern with aliasing imap to the NLB is that
  # imap.<control_domain>:25 would then reach the smtp-in listener instead
  # of erroring out; in practice nothing uses that name on that port (no
  # MX record points at imap, and the same alias has existed in the
  # PUBLIC zone since day one with no observed harm).
  #
  # allow_overwrite covers a legacy drift case: prod's private zone has
  # historically held a manually-added A record for imap pointing at a
  # since-decommissioned container IP. With this flag set, the apply
  # replaces that drift with the alias instead of failing on a "record
  # already exists" conflict.
  for_each        = toset(["imap", "smtp-out", "smtp-in"])
  zone_id         = var.private_zone_id
  name            = each.key
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_lb.elb.dns_name
    zone_id                = aws_lb.elb.zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "srv" {
  for_each = {
    "_submission._tcp" = {
      port = 587
      host = "smtp-out.${var.control_domain}"
    },
    "_imaps._tcp" = {
      port = 993
      host = "imap.${var.control_domain}"
    },
    "_imap._tcp" = {
      port = 0
      host = "."
    },
    "_pop3._tcp" = {
      port = 0
      host = "."
    },
    "_pop3s._tcp" = {
      port = 0
      host = "."
    }
  }
  zone_id = var.zone_id
  name    = each.key
  type    = "SRV"
  ttl     = 3600
  records = [
    "0 1 ${each.value.port} ${each.value.host}"
  ]
}