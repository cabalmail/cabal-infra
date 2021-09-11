resource "aws_efs_file_system" "cabal_efs" {
  encrypted = true
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  tags      = {
    Name = "cabal-efs"
  }
}

resource "aws_security_group" "cabal_efs_sg" {
   name   = "cabal-efs-sg"
   vpc_id = var.vpc.id

   ingress {
     cidr_blocks = [vpc.cidr_block]
     from_port   = 2049
     to_port     = 2049
     protocol    = "tcp"
   }

   egress {
     cidr_blocks = [vpc.cidr_block]
     from_port   = 0
     to_port     = 0
     protocol    = -1
   }
 }

resource "aws_efs_mount_target" "cabal_efs_mount_target" {
  count           = length(var.private_subnets)
  file_system_id  = aws_efs_file_system.cabal_efs.id
  subnet_id       = var.private_subnets[count.index].id
  security_groups = [aws_security_group.cabal_efs_sg.id]
}