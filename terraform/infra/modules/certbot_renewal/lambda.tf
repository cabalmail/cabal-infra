resource "aws_cloudwatch_log_group" "certbot" {
  name              = "/cabal/lambda/certbot-renewal"
  retention_in_days = 30
}

resource "aws_lambda_function" "certbot" {
  function_name = "cabal-certbot-renewal"
  role          = aws_iam_role.certbot_lambda.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.certbot.repository_url}:${var.image_tag}"
  timeout       = 300
  memory_size   = 512
  architectures = ["arm64"]

  environment {
    variables = {
      CONTROL_DOMAIN    = var.control_domain
      EMAIL             = var.email
      ECS_CLUSTER_NAME  = var.ecs_cluster_name
      ECS_SERVICE_NAMES = join(",", var.ecs_service_names)
    }
  }

  logging_config {
    log_group  = aws_cloudwatch_log_group.certbot.name
    log_format = "Text"
  }
}
