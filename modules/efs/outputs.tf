output "efs_dns" {
  value = aws_efs_file_system.cabal_efs.dns_name
}