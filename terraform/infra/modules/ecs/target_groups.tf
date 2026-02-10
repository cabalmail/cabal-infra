/**
* ECS-owned NLB target groups (target_type = "ip").
*
* These are separate from the existing instance-type target groups in the ELB
* module, which continue to serve the ASG-based infrastructure. During the
* parallel-run transition period (Phase 7), both sets of target groups exist.
* The NLB listeners initially point to the old (instance) target groups. Once
* ECS containers are validated, the listeners are switched to these ip-type
* target groups and the old ASG infrastructure is decommissioned.
*/

resource "aws_lb_target_group" "imap" {
  name                 = "cabal-ecs-imap-tg"
  port                 = 143
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
    port                = 143
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "relay" {
  name                 = "cabal-ecs-relay-tg"
  port                 = 25
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
    port                = 25
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "submission" {
  name                 = "cabal-ecs-submission-tg"
  port                 = 465
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
    port                = 465
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "starttls" {
  name                 = "cabal-ecs-starttls-tg"
  port                 = 587
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
    port                = 587
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  lifecycle {
    create_before_destroy = true
  }
}
