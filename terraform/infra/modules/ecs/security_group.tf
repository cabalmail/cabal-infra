/**
* Security groups for ECS tasks (one per tier).
*
* These mirror the ASG module security groups but are attached to ECS tasks
* running in awsvpc mode rather than EC2 instances.
*/

resource "aws_security_group" "tier" {
  for_each    = local.tiers
  name        = "cabal-ecs-${each.key}-sg"
  description = "Allow ${each.key} inbound traffic"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "tier_egress" {
  for_each          = local.tiers
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-egress-sgr
  description       = "Allow all outgoing"
  security_group_id = aws_security_group.tier[each.key].id
}

resource "aws_security_group_rule" "tier_ingress_public" {
  for_each          = local.public_ingress
  type              = "ingress"
  protocol          = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  description       = "Allow incoming port ${each.value.port} ${each.value.tier} from anywhere"
  security_group_id = aws_security_group.tier[each.value.tier].id
}

resource "aws_security_group_rule" "tier_ingress_private" {
  for_each          = local.private_ingress
  type              = "ingress"
  protocol          = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_blocks       = [var.cidr_block]
  description       = "Allow incoming port ${each.value.port} ${each.value.tier} from VPC"
  security_group_id = aws_security_group.tier[each.value.tier].id
}
