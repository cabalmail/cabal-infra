/**
* Creates an Elastic Filesystem for the mailstore. This filesystem is mounted on IMAP machines on the /home directory.
*/

resource "aws_efs_file_system" "mailstore" {
  encrypted = true
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  tags = {
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

# Access point for the shared smtp-out sendmail MTA queue.
#
# Persisting /var/spool/mqueue on EFS lets a replaced smtp-out task hand
# off its in-flight retries to whichever sibling task next scans the
# shared queue. Sendmail's classic shared-NFS queue pattern (fcntl
# F_SETLK on each qf control file) provides the correctness guarantee.
# See docs/0.9.x/smtp-out-queue-persistence-plan.md.
#
# Ownership matches the AL2023 sendmail rpm default for /var/spool/mqueue:
# root:mail (uid=0, gid=12) mode 0700. Verified in image; smmsp (gid=51)
# owns clientmqueue, which we do not persist.
#
# No POSIX user override on the access point itself - sendmail manages
# the per-file qf/df/xf/tf ownership during the privilege drops between
# the listener and the queue runner; the access point only enforces the
# root-directory boundary and the initial creation owner.
resource "aws_efs_access_point" "smtp_queue" {
  file_system_id = aws_efs_file_system.mailstore.id

  root_directory {
    path = "/smtp-queue"
    creation_info {
      owner_uid   = 0
      owner_gid   = 12
      permissions = "0700"
    }
  }

  tags = {
    Name = "cabal-smtp-queue"
  }
}