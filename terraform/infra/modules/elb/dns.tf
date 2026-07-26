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
  # imap is included even though the NLB carries no IMAP listener: the
  # name must still RESOLVE inside the VPC (the private zone shadows the
  # public one, so a missing record here is NXDOMAIN, not a fall-through),
  # and the API Lambdas' fallback path dials imap.<control_domain> when
  # IMAP_INTERNAL_HOST is unset. A resolvable name that refuses the
  # connection beats one that fails DNS - the failure is legible.
  #
  # Container-to-container IMAP delivery (smtp-out -> imap LMTP/SMTP) still
  # uses Cloud Map's imap.cabal.internal, which routes directly to the
  # container's private IP on port 143 and bypasses the NLB. See
  # modules/ecs/service_discovery.tf.
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
    # IMAP is not publicly offered (mailbox access is Cabalmail-client-only,
    # via the Lambda API); port 0 / host "." is RFC 6186's way of saying so,
    # which stops autodiscovering clients from probing a dead endpoint.
    "_imaps._tcp" = {
      port = 0
      host = "."
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