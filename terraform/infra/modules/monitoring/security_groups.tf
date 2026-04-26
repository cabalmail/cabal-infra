# ── Security groups for the monitoring ALB, Kuma task, ntfy task ─

resource "aws_security_group" "alb" {
  name        = "cabal-uptime-alb"
  description = "Public ALB for Uptime Kuma (Cognito-authenticated) and ntfy (token-authenticated)."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "alb_https_in" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet. Kuma path enforces Cognito; ntfy path enforces token auth in-app."
}

resource "aws_security_group_rule" "alb_https_out" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.alb.id
  description       = "Outbound HTTPS for ALB authenticate-cognito token exchange against the Cognito hosted UI domain."
}

resource "aws_security_group_rule" "alb_to_kuma" {
  type                     = "egress"
  from_port                = 3001
  to_port                  = 3001
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.kuma.id
  security_group_id        = aws_security_group.alb.id
  description              = "ALB forwards to Kuma task on 3001."
}

resource "aws_security_group_rule" "alb_to_ntfy" {
  type                     = "egress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ntfy.id
  security_group_id        = aws_security_group.alb.id
  description              = "ALB forwards to ntfy task on 80."
}

resource "aws_security_group" "kuma" {
  name        = "cabal-uptime-kuma"
  description = "Uptime Kuma ECS task."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "kuma_from_alb" {
  type                     = "ingress"
  from_port                = 3001
  to_port                  = 3001
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.kuma.id
  description              = "Kuma accepts traffic from the uptime ALB."
}

resource "aws_security_group_rule" "kuma_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.kuma.id
  description       = "Outbound for probes (TCP/HTTP), DNS, ECR, CloudWatch, Lambda URL."
}

resource "aws_security_group" "ntfy" {
  name        = "cabal-ntfy"
  description = "Self-hosted ntfy ECS task."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "ntfy_from_alb" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.ntfy.id
  description              = "ntfy accepts traffic from the uptime ALB."
}

resource "aws_security_group_rule" "ntfy_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.ntfy.id
  description       = "Outbound for DNS, ECR, CloudWatch, SSM (ECS Exec)."
}
