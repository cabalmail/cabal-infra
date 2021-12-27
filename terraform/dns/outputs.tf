output "Update the registration for your control domain with these name servers. See README.md for more information." {
  value = aws_route53_zone.cabal_control_zone.name_servers
}

output "Create environment variables with your Github repo. See README.md for more information."{
  value = {
    COGNITO_USER_POOL_ID = module.pool.user_pool_id
    COGNITO_CLIENT_ID    = module.pool.user_pool_client_id
    AWS_S3_BUCKET        = aws_s3_bucket.react_app.id
  }
}