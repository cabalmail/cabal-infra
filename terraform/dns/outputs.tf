output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}

output "aws_s3_bucket" {
  value = aws_s3_bucket.react_app.id
}

output "aws_ecr_repository_registry_id" {
  value = aws_ecr_repository.container_repo.registry_id
}

output "aws_ecr_repository_repository_url" {
  value = aws_ecr_repository.container_repo.repository_url
}