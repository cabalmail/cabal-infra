/**
* Stands up the following resources to implement a web application that allows users to manage (create and revoke) their email addresses:
*
* - S3 bucket for static assets
* - Static assets as objects stored in S3
* - Lambda functions for three calls: new address, list addresses, revoke address
* - API Gateway for mediating access to the Lambda functioins
* - CloudFront to cache and accelerate the application
* - DNS alias for the application
* - SSM documents for propagating changes to the IMAP and SMTP servers (still in development)
*
*/

# Password for IMAP admin
resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "()-_=+[]{}<>:"
}

# Save admin password in parameter store.
resource "aws_ssm_parameter" "password" {
  name        = "/cabal/master_password"
  description = "Master IMAP password"
  type        = "SecureString"
  value       = random_password.password.result
}

resource "aws_api_gateway_rest_api" "gateway" {
  name = "cabal_gateway"
}

resource "aws_api_gateway_authorizer" "api_auth" {
  name                   = "cabal_pool"
  rest_api_id            = aws_api_gateway_rest_api.gateway.id
  type                   = "COGNITO_USER_POOLS"
  provider_arns          = [ join("",[
    "arn:aws:cognito-idp:",
    var.region,
    ":",
    data.aws_caller_identity.current.account_id,
    ":userpool/",
    var.user_pool_id
  ]) ]
}

data "aws_s3_object" "lambda_layer_hash" {
  for_each = local.lambda_layers
  bucket   = var.bucket
  key      = "/lambda/${each.key}.zip.base64sha256"
}

resource "aws_lambda_layer_version" "layer" {
  for_each            = local.lambda_layers
  layer_name          = each.key
  compatible_runtimes = [each.value.runtime]
  s3_bucket           = var.bucket
  s3_key              = "lambda/${each.key}.zip"
  source_code_hash    = data.aws_s3_object.lambda_layer_hash[each.key].body
}

module "cabal_method" {
  for_each         = local.lambdas
  source           = "./modules/call"
  name             = each.key
  runtime          = each.value.runtime
  type             = each.value.type
  layer_arns       = each.value.type [aws_lambda_layer_version.layer[each.value.type].arn]
  method           = each.value.method
  memory           = each.value.memory
  region           = var.region
  account          = data.aws_caller_identity.current.account_id
  gateway_id       = aws_api_gateway_rest_api.gateway.id
  root_resource_id = aws_api_gateway_rest_api.gateway.root_resource_id
  authorizer       = aws_api_gateway_authorizer.api_auth.id
  control_domain   = var.control_domain
  relay_ips        = var.relay_ips
  repo             = var.repo
  domains          = var.domains
  bucket           = var.bucket
}

resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.gateway.id
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_rest_api.gateway,
      [for k, v in local.lambdas : module.cabal_method[k].hash_key]
    ]))
  }
  lifecycle {
    create_before_destroy = true
  }
}

#tfsec:ignore:aws-api-gateway-enable-access-logging
#tfsec:ignore:aws-api-gateway-enable-tracing
resource "aws_api_gateway_stage" "api_stage" {
  deployment_id         = aws_api_gateway_deployment.deployment.id
  rest_api_id           = aws_api_gateway_rest_api.gateway.id
  stage_name            = var.stage_name
  cache_cluster_enabled = false
  cache_cluster_size    = "0.5"
}

resource "aws_iam_role" "cloudwatch" {
  name               = "cabal_cloudwatch_role"
  assume_role_policy = <<DOC
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TheSloth",
      "Effect": "Allow",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
DOC
}

resource "aws_iam_role_policy" "cloudwatch" {
  name   = "cabal_cloudwatch_role"
  role   = aws_iam_role.cloudwatch.id
  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:FilterLogEvents",
        "logs:GetLogEvents",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:API-Gateway-Execution-Logs_*/${var.stage_name}:*"
    }
  ]
}
POLICY
}

resource "aws_api_gateway_account" "apigw_account" {
  cloudwatch_role_arn = aws_iam_role.cloudwatch.arn
}

resource "aws_api_gateway_method_settings" "general_settings" {
  rest_api_id = aws_api_gateway_rest_api.gateway.id
  stage_name  = aws_api_gateway_stage.api_stage.stage_name
  method_path = "*/*"
  settings {
    metrics_enabled        = true
    data_trace_enabled     = true
    logging_level          = "INFO"
    throttling_rate_limit  = 100
    throttling_burst_limit = 50
  }
}

resource "aws_api_gateway_method_settings" "cache_settings" {
  for_each    = local.lambdas
  rest_api_id = aws_api_gateway_rest_api.gateway.id
  stage_name  = aws_api_gateway_stage.api_stage.stage_name
  method_path = "${each.key}/${each.value.method}"
  settings {
    caching_enabled      = each.value.cache
    cache_ttl_in_seconds = each.value.cache_ttl
  }
}
