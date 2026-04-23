# ── Security groups for the Kuma ALB and task ──────────────────

resource "aws_security_group" "alb" {
  name        = "cabal-uptime-alb"
  description = "Public ALB for Uptime Kuma (Cognito-authenticated)."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "alb_https_in" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet; Cognito auth enforced at the listener."
}

resource "aws_security_group_rule" "alb_to_task" {
  type                     = "egress"
  from_port                = 3001
  to_port                  = 3001
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.kuma.id
  security_group_id        = aws_security_group.alb.id
  description              = "ALB forwards to Kuma task on 3001."
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
