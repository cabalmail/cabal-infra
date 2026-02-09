output "repository_urls" {
  value       = { for k, v in aws_ecr_repository.tier : k => v.repository_url }
  description = "Map of tier name to ECR repository URL."
}

output "repository_arns" {
  value       = { for k, v in aws_ecr_repository.tier : k => v.arn }
  description = "Map of tier name to ECR repository ARN."
}
