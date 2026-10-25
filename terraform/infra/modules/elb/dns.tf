# The tier hostnames. These are the only records for these names: the VPC no
# longer has a private zone covering the control domain (#2064), so queries
# from inside the VPC resolve here as well. An internal-only answer for one of
# these names needs a private zone named for THAT name, never for the control
# domain - a zone named for the control domain is authoritative for every
# address subdomain too, which is the defect #2064 records.
#
# imap is in the set even though the NLB carries no IMAP listener: the name
# must still RESOLVE (the API Lambdas' fallback path dials imap.<control
# _domain> when IMAP_INTERNAL_HOST is unset, and a resolvable name that
# refuses the connection beats one that fails DNS). Container-to-container
# IMAP delivery uses Cloud Map's imap.cabal.internal and bypasses the NLB;
# see modules/ecs/service_discovery.tf.
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

resource "aws_route53_record" "srv" {
  for_each = {
    # Submission is not publicly offered (sending goes through the
    # Cabalmail clients via the Lambda API); port 0 / host "." is RFC
    # 6186's way of saying so, which stops autodiscovering clients from
    # probing a dead endpoint.
    "_submission._tcp" = {
      port = 0
      host = "."
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