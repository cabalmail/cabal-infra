output "efs_dns" {
  value = aws_efs_file_system.mailstore.dns_name
}