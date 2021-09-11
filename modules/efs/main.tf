resource "aws_efs_file_system" "cabal_efs" {
  encrypted = true
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  tags      = {
    Name                 = "cabal-efs"
  }
}

resource "aws_efs_mount_target" "cabal_efs_mount_target" {
  count          = length(var.private_subnets)
  file_system_id = aws_efs_file_system.cabal_efs.id
  subnet_id      = var.private_subnets[count.index].id
}