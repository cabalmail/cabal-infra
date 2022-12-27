output "master_password" {
  value = random_password.password.result
}

output "ssm_document_arn" {
  value = aws_ssm_document.run_chef_now.arn
}