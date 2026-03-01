resource "aws_lb_target_group" "submission" {
  name                 = "cabal-smtp-submission-tg"
  port                 = "465"
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
    port                = 465
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

resource "aws_lb_listener" "submission" {
  load_balancer_arn = aws_lb.elb.arn
  protocol          = "TLS"
  port              = "465"
  certificate_arn   = var.cert_arn
  default_action {
    type             = "forward"
    target_group_arn = var.ecs_submission_target_group_arn != "" ? var.ecs_submission_target_group_arn : aws_lb_target_group.submission.arn
  }
}

resource "aws_lb_target_group" "starttls" {
  name                 = "cabal-smtp-starttls-tg"
  port                 = "587"
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
    port                = 587
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

resource "aws_lb_listener" "starttls" {
  load_balancer_arn = aws_lb.elb.arn
  protocol          = "TCP"
  port              = "587"
  default_action {
    type             = "forward"
    target_group_arn = var.ecs_starttls_target_group_arn != "" ? var.ecs_starttls_target_group_arn : aws_lb_target_group.starttls.arn
  }
}