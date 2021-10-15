data "aws_caller_identity" "current" {}

resource "aws_api_gateway_rest_api" "cabal_gateway" {
  name = "cabal_gateway"
}

resource "aws_api_gateway_authorizer" "cabal_api_authorizer" {
  name                   = "cabal_pool"
  rest_api_id            = aws_api_gateway_rest_api.cabal_gateway.id
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
  gateway_id       = aws_api_gateway_rest_api.cabal_gateway.id
  root_resource_id = aws_api_gateway_rest_api.cabal_gateway.root_resource_id
  authorizer       = aws_api_gateway_authorizer.cabal_api_authorizer.id
  control_domain   = var.control_domain
}

module "cabal_new_method" {
  source           = "./modules/call"
  name             = "new"
  runtime          = "nodejs14.x"
  method           = "POST"
  region           = var.region
  account          = data.aws_caller_identity.current.account_id
  gateway_id       = aws_api_gateway_rest_api.cabal_gateway.id
  root_resource_id = aws_api_gateway_rest_api.cabal_gateway.root_resource_id
  authorizer       = aws_api_gateway_authorizer.cabal_api_authorizer.id
  control_domain   = var.control_domain
}

module "cabal_revoke_method" {
  source           = "./modules/call"
  name             = "revoke"
  runtime          = "nodejs14.x"
  method           = "DELETE"
  region           = var.region
  account          = data.aws_caller_identity.current.account_id
  gateway_id       = aws_api_gateway_rest_api.cabal_gateway.id
  root_resource_id = aws_api_gateway_rest_api.cabal_gateway.root_resource_id
  authorizer       = aws_api_gateway_authorizer.cabal_api_authorizer.id
  control_domain   = var.control_domain
}

resource "aws_api_gateway_deployment" "cabal_api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.cabal_gateway.id
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_rest_api.cabal_gateway.body,
      module.cabal_list_method.hash_key,
      module.cabal_new_method.hash_key,
      module.cabal_revoke_method.hash_key,
    ]))
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "cabal_api_stage" {
  deployment_id = aws_api_gateway_deployment.cabal_api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.cabal_gateway.id
  stage_name    = "prod"
}