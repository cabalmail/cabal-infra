output "repository_urls" {
  value = merge(
    { for k, v in aws_ecr_repository.tier : k => v.repository_url },
    { for k, v in aws_ecr_repository.monitoring : k => v.repository_url },
  )
  description = "Map of tier name to ECR repository URL."
}

output "repository_arns" {
  value = merge(
    { for k, v in aws_ecr_repository.tier : k => v.arn },
    { for k, v in aws_ecr_repository.monitoring : k => v.arn },
  )
  description = "Map of tier name to ECR repository ARN."
}
