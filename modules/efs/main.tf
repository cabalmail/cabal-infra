resource "aws_efs_file_system" "cabal_efs" {
  encrypted = true
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  tags      = {
    Name                 = "cabal-efs"
  }
}