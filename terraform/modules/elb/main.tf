resource "aws_lb" "cabal_nlb" {
  name                             = "cabal-nlb"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = var.public_subnets[*].id
  enable_cross_zone_load_balancing = false
  tags                             = {
    Name = "cabal-nlb"
  }
}

resource "aws_lb_target_group" "cabal_imap_tg" {
  name                 = "cabal-imap-tg"
  port                 = "143"
  protocol             = "TCP"
  vpc_id               = var.vpc.id
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
  depends_on           = [
    aws_lb.cabal_nlb
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "cabal_imaps_listener" {
  load_balancer_arn = aws_lb.cabal_nlb.arn
  protocol          = "TLS"
  port              = "993"
  certificate_arn   = var.cert_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cabal_imap_tg.arn
  }
}

resource "aws_lb_target_group" "cabal_smtp_tg" {
  name                 = "cabal-smtp-tg"
  port                 = "587"
  protocol             = "TCP"
  vpc_id               = var.vpc.id
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
  depends_on           = [
    aws_lb.cabal_nlb
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "cabal_smtp_relay_tg" {
  name                 = "cabal-smtp-relay-tg"
  port                 = "25"
  protocol             = "TCP"
  vpc_id               = var.vpc.id
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
  depends_on           = [
    aws_lb.cabal_nlb
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "cabal_smtp_relay_listener" {
  load_balancer_arn = aws_lb.cabal_nlb.arn
  protocol          = "TCP"
  port              = "25"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cabal_smtp_relay_tg.arn
  }
}

resource "aws_lb_target_group" "cabal_smtp_submission_tg" {
  name                 = "cabal-smtp-submission-tg"
  port                 = "25"
  protocol             = "TCP"
  vpc_id               = var.vpc.id
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
  depends_on           = [
    aws_lb.cabal_nlb
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "cabal_smtp_submission_listener" {
  load_balancer_arn = aws_lb.cabal_nlb.arn
  protocol          = "TCP"
  port              = "465"
  certificate_arn   = var.cert_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cabal_smtp_submission_tg.arn
  }
}