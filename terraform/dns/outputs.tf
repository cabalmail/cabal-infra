output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}

output "aws_s3_bucket" {
  value = aws_s3_bucket.react_app.id
}

output "aws_ecr_repository" {
  value = aws_ssm_parameter.container_repo.name
}