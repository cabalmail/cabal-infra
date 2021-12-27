output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}

output "github_env_vars"{
  value = {
    COGNITO_USER_POOL_ID = module.pool.user_pool_id
    COGNITO_CLIENT_ID    = module.pool.user_pool_client_id
    AWS_S3_BUCKET        = aws_s3_bucket.react_app.id
  }
}