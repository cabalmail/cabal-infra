output "master_password" {
  value = random_password.password.result
}

output "ssm_document_arn" {
  value = aws_ssm_document.run_chef_now.arn
}

output "node_config" {
  value = aws_s3_object.node_config.key
}

output "cf_config" {
  value = aws_ssm_parameter.cf_distribution.name
}