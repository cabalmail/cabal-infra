locals {
  repo = "https://github.com/ccarr-cabal/cabal-infra/tree/main"
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
    terraform_repo       = local.repo
  }
}

resource "aws_lb_target_group" "cabal_imap_tg" {
  name                 = "cabal-imap-tg"
  port                 = "143"
  protocol             = "TCP"
  vpc_id               = var.vpc.id
  deregistration_delay = 30
  stickiness           = [
    type    = source_ip,
    enabled = true
  ]
  health_check         = [
    enabled           = true
    interval          = 120
    port              = 143
    protocol          = "TCP"
    healthy_threshold = 2
  ]
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
  # certificate_arn   = TODO: get from cert module
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cabal_imap_tg.arn
  }
  tags              = {
    Name                 = "cabal-imaps-listener"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_lb_target_group" "cabal_smtp_tg" {
  name                 = "cabal-smtp-tg"
  port                 = "587"
  protocol             = "TCP"
  vpc_id               = var.vpc.id
  deregistration_delay = 30
  stickiness           = [
    type    = source_ip,
    enabled = true
  ]
  health_check         = [
    enabled           = true
    interval          = 120
    port              = 587
    protocol          = "TCP"
    healthy_threshold = 2
  ]
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
  tags              = {
    Name                 = "cabal-smtp-relay-listener"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
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
  tags              = {
    Name                 = "cabal-smtp-submission-listener"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}

resource "aws_lb_target_group" "cabal_imap_tg" {
  name                 = "cabal-imap-tg"
  port                 = "143"
  protocol             = "TCP"
  vpc_id               = var.vpc.id
  deregistration_delay = 30
  stickiness           = [
    type    = source_ip,
    enabled = true
  ]
  health_check         = [
    enabled           = true
    interval          = 120
    port              = 143
    protocol          = "TCP"
    healthy_threshold = 2
  ]
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
  # certificate_arn   = TODO: get from dns module?
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cabal_imap_tg.arn
  }
  tags              = {
    Name                 = "cabal-imaps-listener"
    managed_by_terraform = "y"
    terraform_repo       = local.repo
  }
}