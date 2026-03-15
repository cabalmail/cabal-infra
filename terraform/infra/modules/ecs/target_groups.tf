/**
* ECS-owned NLB target groups (target_type = "ip").
*
* Production NLB listeners in the ELB module forward to these target groups.
* The old instance-type target groups in the ELB module remain for the ASG
* modules but are no longer referenced by any active listeners.
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

  stickiness {
    type    = "source_ip"
    enabled = true
  }

  health_check {
    enabled             = true
    interval            = 30
    port                = "traffic-port"
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = var.unhealthy_threshold
  }

  # Note: create_before_destroy is not used here because fixed target
  # group names cause naming collisions during replacement.
}

# Staging NLB listeners removed — production listeners in the ELB module
# now forward directly to these ECS target groups (Phase 7 cutover).
