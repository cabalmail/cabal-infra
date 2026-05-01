resource "aws_cloudwatch_log_group" "certbot" {
  name              = "/cabal/lambda/certbot-renewal"
  retention_in_days = 30
}

# Phase 4 of docs/0.9.0/build-deploy-simplification-plan.md.
# When /cabal/deployed_image_tag is the bootstrap sentinel, the
# cabal/certbot-renewal ECR repo is still empty (infra.yml runs first,
# before app.yml has ever pushed an image), so the Lambda is created
# with a public Lambda runtime image. The phase 2 lifecycle clause on
# image_uri keeps subsequent app.yml deploys from being clobbered by a
# topology-only Terraform apply. The placeholder Lambda is never
# actually invoked - the EventBridge schedule fires the renewal Lambda
# but the bootstrap window is short enough that the next app.yml run
# replaces the image before the schedule trips.
locals {
  placeholder_image_tag = "bootstrap-placeholder"
  placeholder_image_uri = "public.ecr.aws/lambda/python:3.13-arm64"
  resolved_image_uri    = var.image_tag == local.placeholder_image_tag ? local.placeholder_image_uri : "${aws_ecr_repository.certbot.repository_url}:${var.image_tag}"
}

resource "aws_lambda_function" "certbot" {
  function_name = "cabal-certbot-renewal"
  role          = aws_iam_role.certbot_lambda.arn
  package_type  = "Image"
  image_uri     = local.resolved_image_uri
  timeout       = 300
  memory_size   = 512
  architectures = ["arm64"]

  environment {
    variables = {
      CONTROL_DOMAIN         = var.control_domain
      EMAIL                  = var.email
      ECS_CLUSTER_NAME       = var.ecs_cluster_name
      ECS_SERVICE_NAMES      = join(",", var.ecs_service_names)
      HEALTHCHECK_PING_PARAM = var.healthcheck_ping_param
    }
  }

  logging_config {
    log_group  = aws_cloudwatch_log_group.certbot.name
    log_format = "Text"
  }

  # Phase 2 of docs/0.9.0/build-deploy-simplification-plan.md: out-of-band
  # Lambda deploys mutate the container image via aws lambda
  # update-function-code --image-uri; ignore image_uri so a topology-only
  # Terraform apply does not roll the update back.
  lifecycle {
    ignore_changes = [image_uri]
  }
}
