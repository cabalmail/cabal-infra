resource "aws_security_group" "cabal_sg" {
  name        = "cabal-${var.type}-sg"
  description = "Allow ${var.type} inbound traffic"
  vpc_id      = var.vpc.id
}

resource "aws_security_group_rule" "allow_all" {
  type              = "egress"
  protocol          = "-1"
  to_port           = 0
  from_port         = 0
  description       = "Allow all outgoing"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.cabal_sg.id
}

resource "aws_security_group_rule" "allow" {
  count             = length(var.ports)
  type              = "ingress"
  protocol          = "tcp"
  to_port           = var.ports[count.index]
  from_port         = var.ports[count.index]
  description       = "Allow incoming port ${var.ports[count.index]} ${var.type} from anywhere"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.cabal_sg.id
}

resource "aws_security_group_rule" "allow_local" {
  count             = length(var.private_ports)
  type              = "ingress"
  protocol          = "tcp"
  to_port           = var.private_ports[count.index]
  from_port         = var.private_ports[count.index]
  description       = "Allow incoming port ${var.private_ports[count.index]} ${var.type} from the local CIDR"
  cidr_blocks       = [var.cidr_block]
  security_group_id = aws_security_group.cabal_sg.id
}