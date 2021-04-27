resource "time_rotating" "cabal_cert_rotator" {
  rotation_days = 1
}

resource "aws_acm_certificate" "cabal_cert" {
  private_key       = var.cert_key
  certificate_body  = var.cert_body
  certificate_chain = var.cert_chain
  tags              = {
    Name                 = "cabal-nlb-${timestamp()}"
    created              = timestamp()
    rotate_after         = timeadd(timestamp(), "7900h")
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      # We want the timestamp computed at create-time,
      # not recomputed with each run.
      tags,
    ]
  }
}

resource "aws_lb" "cabal_nlb" {
  name                             = "cabal-nlb"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = var.public_subnets[*].id
  enable_cross_zone_load_balancing = false
  tags                             = {
    Name                 = "cabal-nlb"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
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
  certificate_arn   = aws_acm_certificate.cabal_cert.id
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

resource "aws_lb_listener" "cabal_smtp_relay_listener" {
  load_balancer_arn = aws_lb.cabal_nlb.arn
  protocol          = "TCP"
  port              = "25"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cabal_smtp_tg.arn
  }
}

resource "aws_lb_listener" "cabal_smtp_submission_listener" {
  load_balancer_arn = aws_lb.cabal_nlb.arn
  protocol          = "TCP"
  port              = "587"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cabal_smtp_tg.arn
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

resource "aws_lb_target_group" "cabal_smtp_submission_tg" {
  name                 = "cabal-smtp-submission-tg"
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