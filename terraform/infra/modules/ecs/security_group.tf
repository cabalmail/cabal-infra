/**
* Security groups for ECS tasks (one per tier).
*
* These mirror the ASG module security groups but are attached to ECS tasks
* running in awsvpc mode rather than EC2 instances.
*/

# ── IMAP security group ───────────────────────────────────────

resource "aws_security_group" "imap" {
  name        = "cabal-ecs-imap-sg"
  description = "Allow IMAP inbound traffic"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "imap_egress" {
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-egress-sgr
  description       = "Allow all outgoing"
  security_group_id = aws_security_group.imap.id
}

resource "aws_security_group_rule" "imap_ingress_143" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 143
  to_port           = 143
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  description       = "Allow IMAP from anywhere"
  security_group_id = aws_security_group.imap.id
}

resource "aws_security_group_rule" "imap_ingress_993" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 993
  to_port           = 993
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  description       = "Allow IMAPS from anywhere"
  security_group_id = aws_security_group.imap.id
}

resource "aws_security_group_rule" "imap_ingress_25" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 25
  to_port           = 25
  cidr_blocks       = [var.cidr_block]
  description       = "Allow SMTP from VPC (relay delivery)"
  security_group_id = aws_security_group.imap.id
}

# ── SMTP-IN security group ────────────────────────────────────

resource "aws_security_group" "smtp_in" {
  name        = "cabal-ecs-smtp-in-sg"
  description = "Allow SMTP inbound traffic"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "smtp_in_egress" {
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-egress-sgr
  description       = "Allow all outgoing"
  security_group_id = aws_security_group.smtp_in.id
}

resource "aws_security_group_rule" "smtp_in_ingress_25" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 25
  to_port           = 25
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  description       = "Allow SMTP from anywhere"
  security_group_id = aws_security_group.smtp_in.id
}

# ── SMTP-OUT security group ───────────────────────────────────

resource "aws_security_group" "smtp_out" {
  name        = "cabal-ecs-smtp-out-sg"
  description = "Allow SMTP outbound submission traffic"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "smtp_out_egress" {
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-egress-sgr
  description       = "Allow all outgoing"
  security_group_id = aws_security_group.smtp_out.id
}

resource "aws_security_group_rule" "smtp_out_ingress_25" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 25
  to_port           = 25
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  description       = "Allow SMTP from anywhere"
  security_group_id = aws_security_group.smtp_out.id
}

resource "aws_security_group_rule" "smtp_out_ingress_465" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 465
  to_port           = 465
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  description       = "Allow SMTP submission from anywhere"
  security_group_id = aws_security_group.smtp_out.id
}

resource "aws_security_group_rule" "smtp_out_ingress_587" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 587
  to_port           = 587
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  description       = "Allow SMTP STARTTLS from anywhere"
  security_group_id = aws_security_group.smtp_out.id
}
