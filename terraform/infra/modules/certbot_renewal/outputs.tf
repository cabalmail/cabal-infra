output "lambda_function_name" {
  value       = aws_lambda_function.certbot.function_name
  description = "Name of the certbot renewal Lambda function."
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.certbot.repository_url
  description = "URL of the ECR repository for the certbot renewal image."
}
