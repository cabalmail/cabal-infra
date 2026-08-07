/**
* NLB target group (target_type = "ip") for the inbound relay - the one
* mail-plane listener (25) the NLB still serves; MX delivery requires
* it forever.
*
* The imap/submission/starttls groups are gone. Their listeners went
* with public IMAP/submission access, a listenerless target group is
* never health-checked by the NLB (Target.NotInUse), and ECS refuses
* UpdateService on a service that references a target group with no
* associated load balancer - so keeping the detached wiring "to avoid
* churn" bricked every deploy to those tiers. Their liveness signal is
* the container-level healthCheck in the task definitions.
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
