resource "aws_efs_file_system" "mailstore" {
  encrypted = true
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  tags      = {
    Name = "cabal-efs"
  }
}

resource "aws_security_group" "mailstore" {
   name   = "cabal-efs-sg"
   vpc_id = var.vpc.id

   ingress {
     cidr_blocks = [var.vpc.cidr_block]
     from_port   = 2049
     to_port     = 2049
     protocol    = "tcp"
   }

   egress {
     cidr_blocks = [var.vpc.cidr_block]
     from_port   = 0
     to_port     = 0
     protocol    = -1
   }
 }

resource "aws_efs_mount_target" "mailstore" {
  count           = length(var.private_subnets)
  file_system_id  = aws_efs_file_system.mailstore.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.mailstore.id]
}