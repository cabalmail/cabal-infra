output "master_password" {
  value = random_password.password.result
}

output "ålayers" {
  value = aws_lambda_layer_version.layer[*].arn
}