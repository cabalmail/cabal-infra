/**
* Cloud Map service discovery for inter-tier communication.
*
* The IMAP container accepts mail for local delivery on port 25.  SMTP-IN
* and SMTP-OUT need to reach it by hostname (via the sendmail mailertable).
* The public NLB cannot be used because its port 25 listener routes to the
* relay (SMTP-IN) target group, not IMAP — creating a loop.
*
* Cloud Map registers the IMAP task's ENI IP directly in a private DNS
* namespace so that smtp-in and smtp-out can connect to it without going
* through the NLB.
*/

resource "aws_service_discovery_private_dns_namespace" "mail" {
  name        = "cabal.local"
  description = "Internal service discovery for ECS mail tiers"
  vpc         = var.vpc_id
}

resource "aws_service_discovery_service" "imap" {
  name = "imap"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.mail.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}
