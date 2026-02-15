/**
* ECS-owned NLB target groups (target_type = "ip").
*
* These are separate from the existing instance-type target groups in the ELB
* module, which continue to serve the ASG-based infrastructure. During the
* parallel-run transition period (Phase 7), both sets of target groups exist.
* The NLB listeners initially point to the old (instance) target groups. Once
* ECS containers are validated, the listeners are switched to these ip-type
* target groups and the old ASG infrastructure is decommissioned.
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
  deregistration_delay = 30

  stickiness {
    type    = "source_ip"
    enabled = true
  }

  health_check {
    enabled             = true
    interval            = 30
    port                = each.value.port
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Staging NLB listeners ──────────────────────────────────────
#
# ECS refuses to register tasks into a target group that is not
# associated with a load balancer. These TCP listeners on high-
# numbered ports associate the ECS target groups with the shared
# NLB without disturbing the production listeners that still
# serve the ASG tiers. Remove these once the production listeners
# are switched to the ECS target groups in Phase 7.

resource "aws_lb_listener" "ecs_staging" {
  for_each          = local.target_groups
  load_balancer_arn = var.nlb_arn
  port              = each.value.staging_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tier[each.key].arn
  }
}
