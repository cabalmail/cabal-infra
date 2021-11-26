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

module "cabal_list_method" {
  source           = "./modules/call"
  name             = "list"
  runtime          = "nodejs14.x"
  method           = "GET"
  region           = var.region
  account          = data.aws_caller_identity.current.account_id
  gateway_id       = aws_api_gateway_rest_api.gateway.id
  root_resource_id = aws_api_gateway_rest_api.gateway.root_resource_id
  authorizer       = aws_api_gateway_authorizer.api_auth.id
  control_domain   = var.control_domain
  relay_ips        = var.relay_ips
  domains          = var.domains
  ssm_documents    = {
    for k, v in aws_ssm_document.run_chef : k => v.arn
  }
}

module "cabal_new_method" {
  source           = "./modules/call"
  name             = "new"
  runtime          = "nodejs14.x"
  method           = "POST"
  region           = var.region
  account          = data.aws_caller_identity.current.account_id
  gateway_id       = aws_api_gateway_rest_api.gateway.id
  root_resource_id = aws_api_gateway_rest_api.gateway.root_resource_id
  authorizer       = aws_api_gateway_authorizer.api_auth.id
  control_domain   = var.control_domain
  relay_ips        = var.relay_ips
  domains          = var.domains
  ssm_documents    = {
    for k, v in aws_ssm_document.run_chef : k => v.arn
  }
}

module "cabal_revoke_method" {
  source           = "./modules/call"
  name             = "revoke"
  runtime          = "nodejs14.x"
  method           = "DELETE"
  region           = var.region
  account          = data.aws_caller_identity.current.account_id
  gateway_id       = aws_api_gateway_rest_api.gateway.id
  root_resource_id = aws_api_gateway_rest_api.gateway.root_resource_id
  authorizer       = aws_api_gateway_authorizer.api_auth.id
  control_domain   = var.control_domain
  relay_ips        = var.relay_ips
  domains          = var.domains
  ssm_documents    = {
    for k, v in aws_ssm_document.run_chef : k => v.arn
  }
}

resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.gateway.id
  triggers = {
    redeployment = sha1(jsonencode([
      jsonencode(aws_api_gateway_rest_api.gateway),
      module.cabal_list_method.hash_key,
      module.cabal_new_method.hash_key,
      module.cabal_revoke_method.hash_key,
    ]))
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "api_stage" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.gateway.id
  stage_name    = "prod"
  depends_on    = [
    aws_api_gateway_method_settings.settings
  ]
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
      "Resource": "*"
    }
  ]
}
POLICY
}

resource "aws_api_gateway_account" "apigw_account" {
  cloudwatch_role_arn = aws_iam_role.cloudwatch.arn
}

resource "aws_api_gateway_method_settings" "settings" {
  rest_api_id = aws_api_gateway_rest_api.gateway.id
  stage_name  = "prod"
  method_path = "*/*"
  settings {
    metrics_enabled        = true
    data_trace_enabled     = true
    logging_level          = "INFO"
    throttling_rate_limit  = 100
    throttling_burst_limit = 50
  }
  depends_on = [
    aws_api_gateway_stage.api_stage
  ]
}