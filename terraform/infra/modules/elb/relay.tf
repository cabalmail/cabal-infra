resource "aws_lb_target_group" "relay" {
  name                 = "cabal-smtp-relay-tg"
  port                 = "25"
  protocol             = "TCP"
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
  depends_on = [
    aws_lb.elb
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "relay" {
  load_balancer_arn = aws_lb.elb.arn
  protocol          = "TCP"
  port              = "25"
  default_action {
    type             = "forward"
    target_group_arn = var.ecs_relay_target_group_arn != "" ? var.ecs_relay_target_group_arn : aws_lb_target_group.relay.arn
  }
}