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

module "cabal_list_mailboxes_method" {
  source           = "./modules/call"
  name             = "list_mailboxes"
  runtime          = "python3.9"
  type             = "python"
  method           = "POST"
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

module "cabal_list_messages_method" {
  source           = "./modules/call"
  name             = "list_messages"
  runtime          = "python3.9"
  type             = "python"
  method           = "POST"
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

module "cabal_list_envelopes_method" {
  source           = "./modules/call"
  name             = "list_envelopes"
  runtime          = "python3.9"
  type             = "python"
  method           = "POST"
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

module "cabal_fetch_message_method" {
  source           = "./modules/call"
  name             = "fetch_message"
  runtime          = "python3.9"
  type             = "python"
  method           = "POST"
  memory           = 2048
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

module "cabal_list_attachments_method" {
  source           = "./modules/call"
  name             = "list_attachments"
  runtime          = "python3.9"
  type             = "python"
  method           = "POST"
  memory           = 2048
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

module "cabal_list_method" {
  source           = "./modules/call"
  name             = "list"
  runtime          = "nodejs14.x"
  type             = "node"
  method           = "GET"
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

module "cabal_new_method" {
  source           = "./modules/call"
  name             = "new"
  runtime          = "nodejs14.x"
  type             = "node"
  method           = "POST"
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

module "cabal_revoke_method" {
  source           = "./modules/call"
  name             = "revoke"
  runtime          = "nodejs14.x"
  type             = "node"
  method           = "DELETE"
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
      jsonencode(aws_api_gateway_rest_api.gateway),
      module.cabal_list_method.hash_key,
      module.cabal_new_method.hash_key,
      module.cabal_revoke_method.hash_key,
      module.cabal_list_mailboxes_method.hash_key,
      module.cabal_list_messages_method.hash_key,
      module.cabal_list_envelopes_method.hash_key,
      module.cabal_fetch_message_method.hash_key,
      module.cabal_list_attachments_method.hash_key
    ]))
  }
  lifecycle {
    create_before_destroy = true
  }
}

#tfsec:ignore:aws-api-gateway-enable-access-logging
#tfsec:ignore:aws-api-gateway-enable-tracing
resource "aws_api_gateway_stage" "api_stage" {
  deployment_id      = aws_api_gateway_deployment.deployment.id
  rest_api_id        = aws_api_gateway_rest_api.gateway.id
  stage_name         = var.stage_name
  cache_cluster_size = "0.5"
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

resource "aws_api_gateway_method_settings" "settings" {
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