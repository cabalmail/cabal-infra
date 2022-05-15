/**
* Creates an Elastic Filesystem for the mailstore. This filesystem is mounted on IMAP machines on the /home directory.
*/

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
   name        = "cabal-efs-sg"
   vpc_id      = var.vpc_id
   description = "Allow EC2 instances to access the mailstore filesystem"

   ingress {
     cidr_blocks = [var.vpc_cidr_block]
     from_port   = 2049
     to_port     = 2049
     protocol    = "tcp"
     description = "Allow EC2 instances to access the mailstore filesystem on port 2049"
  }

   egress {
     cidr_blocks = [var.vpc_cidr_block]
     from_port   = 0
     to_port     = 0
     protocol    = -1
     description = "Allow all outgoing"
   }
 }

resource "aws_efs_mount_target" "mailstore" {
  count           = length(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.mailstore.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.mailstore.id]
}