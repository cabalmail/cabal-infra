/**
* NLB target groups (target_type = "ip").
*
* Only the relay group still has an NLB listener (25, in the ELB module)
* and is health-checked by the NLB. The imap/submission/starttls groups
* lost their listeners with the public IMAP/submission removal; the NLB
* holds their targets in Target.NotInUse and performs no health checks
* on them. They stay wired to the services anyway because removing a
* service's load_balancer block forces service replacement - liveness
* for those tiers comes from the container-level healthCheck in their
* task definitions instead.
*
* Keyed by function (imap, relay, submission, starttls) rather than tier
* because smtp-out maps to two target groups.
*/

resource "aws_lb_target_group" "tier" {
  for_each             = local.target_groups
  name                 = "cabal-ecs-${each.key}-tg"
  port                 = each.value.port
  protocol             = "TCP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay
  # null = AWS default (disabled for ip-type TCP targets). See the
  # per-function rationale on local.target_groups.
  preserve_client_ip = each.value.preserve_client_ip

  stickiness {
    type    = "source_ip"
    enabled = true
  }

  health_check {
    enabled             = true
    interval            = each.value.health_check_interval
    port                = "traffic-port"
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = var.unhealthy_threshold
  }

  # Note: create_before_destroy is not used here because fixed target
  # group names cause naming collisions during replacement.
}

# Staging NLB listeners removed - the remaining production listener in
# the ELB module (relay, 25) forwards directly to its ECS target group
# (Phase 7 cutover).
