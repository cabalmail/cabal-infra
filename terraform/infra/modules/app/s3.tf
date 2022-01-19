resource "aws_s3_bucket_object" "website_config" {
  bucket       = jsondecode(data.aws_ssm_parameter.s3.value).bucket
  key          = "/config.js"
  content_type = "text/javascript"
  content      = templatefile("${path.module}/templates/config.js", {
    pool_id        = var.user_pool_id,
    pool_client_id = var.user_pool_client_id,
    region         = var.region,
    invoke_url     = "${aws_api_gateway_deployment.deployment.invoke_url}prod",
    domains        = var.domains,
    control_domain = var.control_domain
  })
  etag         = md5(templatefile("${path.module}/templates/config.js", {
      pool_id        = var.user_pool_id,
      pool_client_id = var.user_pool_client_id,
      region         = var.region,
      invoke_url     = "${aws_api_gateway_deployment.deployment.invoke_url}prod",
      domains        = var.domains,
      control_domain = var.control_domain
    })
  )
}
