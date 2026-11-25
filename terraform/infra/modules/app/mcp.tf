# Read-only MCP endpoint for agents (docs/tentative/agent-mail-access-plan.md,
# Phase A; operator guide in docs/agent-access.md).
#
#   POST /mcp  ->  authorize_agent (REQUEST authorizer, bearer token)
#              ->  mcp (stateless streamable-HTTP JSON-RPC, EXAMINE-only IMAP)
#
# The route sits on the same REST API and stage as the Cognito endpoints but
# authenticates differently: an MCP client cannot run the Cognito SRP + TOTP
# dance, so it presents a long-lived `cbl_agt_...` bearer token minted by the
# owner through new_agent_grant. The authorizer looks the token's hash up in
# cabal-agent-grants and hands the grant (user, id, access, folders) to the
# mcp Lambda in requestContext.authorizer. Neither function is built by the
# call module, because that module hard-wires COGNITO_USER_POOLS and a policy
# sized for the full mail surface; these two get roles scoped to what they do.

# -- Authorizer --------------------------------------------------

resource "aws_iam_role" "authorize_agent" {
  name = "authorize_agent_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Sid       = "authorizeAgentSid"
      }
    ]
  })
}

resource "aws_iam_role_policy" "authorize_agent" {
  name = "authorize_agent_policy"
  role = aws_iam_role.authorize_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetItem to resolve a token hash to its grant; UpdateItem only for
        # the throttled last_used_at stamp. No Query: the authorizer never
        # enumerates a user's grants.
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
        ]
        Resource = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/cabal-agent-grants"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.authorize_agent.arn}:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "authorize_agent" {
  name              = "/cabal/lambda/authorize_agent"
  retention_in_days = 365
}

data "aws_s3_object" "authorize_agent_hash" {
  bucket = var.bucket
  key    = "lambda/authorize_agent.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "authorize_agent" {
  #checkov:skip=CKV_AWS_115: shared-pool concurrency is the point; a per-function reserve would starve the API lambdas
  #checkov:skip=CKV_AWS_116: invoked synchronously by API Gateway, which returns the failure to the caller; there is no async event to dead-letter
  #checkov:skip=CKV_AWS_117: touches only DynamoDB; a VPC placement would add a NAT dependency and cold-start latency to every /mcp request for zero data-plane gain
  #checkov:skip=CKV_AWS_272: code-signing is not part of this repo's Lambda supply chain (zips are hash-pinned at build; see build-api-one.sh)
  #checkov:skip=CKV_AWS_50: X-Ray tracing is not used anywhere in this stack (see the tfsec ignore above)
  s3_bucket        = var.bucket
  s3_key           = "lambda/authorize_agent.zip"
  source_code_hash = data.aws_s3_object.authorize_agent_hash.body
  function_name    = "authorize_agent"
  role             = aws_iam_role.authorize_agent.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  # One GetItem and at most one conditional UpdateItem.
  timeout     = 10
  memory_size = 128

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.authorize_agent.name
  }

  depends_on = [
    aws_cloudwatch_log_group.authorize_agent,
    aws_iam_role_policy.authorize_agent,
  ]

  # Out-of-band Lambda deploys mutate code via aws lambda update-function-code;
  # ignore these so a topology-only Terraform apply does not roll the update
  # back (matches the call module).
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

resource "aws_api_gateway_authorizer" "agent" {
  name           = "cabal_agent"
  rest_api_id    = aws_api_gateway_rest_api.gateway.id
  type           = "REQUEST"
  authorizer_uri = aws_lambda_function.authorize_agent.invoke_arn
  # A request without an Authorization header is refused by API Gateway
  # before the authorizer runs.
  identity_source = "method.request.header.Authorization"
  # No caching: a revoked grant stops working on the very next request, and
  # the cached policy would otherwise be keyed on the raw token.
  authorizer_result_ttl_in_seconds = 0
}

resource "aws_lambda_permission" "authorize_agent" {
  statement_id  = "AllowExecutionFromAPIGatewayAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorize_agent.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "arn:aws:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.gateway.id}/authorizers/${aws_api_gateway_authorizer.agent.id}"
}

# -- MCP server --------------------------------------------------

resource "aws_iam_role" "mcp" {
  name = "mcp_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Sid       = "mcpSid"
      }
    ]
  })
}

# Deliberately narrower than the call module's policy: no DynamoDB, no S3
# message cache, no Route 53, SNS, SQS or Cognito. The server only opens
# EXAMINE (read-only) IMAP sessions, so the SSM parameters helper.py reads at
# import and per call are the only AWS data it needs.
resource "aws_iam_role_policy" "mcp" {
  #checkov:skip=CKV_AWS_290:the only unconstrained write actions are the EC2 ENI trio for VPC-attached Lambda networking - Lambda-managed interface ARNs only exist at runtime (mirrors AWSLambdaVPCAccessExecutionRole)
  #checkov:skip=CKV_AWS_355:same statement - ec2:Describe* has no resource-level scoping and the ENI create/delete targets are runtime values
  name = "mcp_policy"
  role = aws_iam_role.mcp.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/master_password",
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/maintenance/imap",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.mcp.arn}:*"
      },
      {
        # iam-wildcard-ok: EC2 ENI actions for VPC-attached Lambda networking
        # (private-IMAP replumb). Lambda-created interface ARNs only exist at
        # runtime and Describe* has no resource-level scoping; mirrors the
        # AWSLambdaVPCAccessExecutionRole managed policy.
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
        ]
        # iam-wildcard-ok: Lambda-managed ENI ARNs only exist at runtime; Describe* has no resource-level scoping
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "mcp" {
  name              = "/cabal/lambda/mcp"
  retention_in_days = 365
}

data "aws_s3_object" "mcp_hash" {
  bucket = var.bucket
  key    = "lambda/mcp.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "mcp" {
  #checkov:skip=CKV_AWS_115: shared-pool concurrency is the point; a per-function reserve would starve the API lambdas
  #checkov:skip=CKV_AWS_116: invoked synchronously by API Gateway, which returns the failure to the caller; there is no async event to dead-letter
  #checkov:skip=CKV_AWS_272: code-signing is not part of this repo's Lambda supply chain (zips are hash-pinned at build; see build-api-one.sh)
  #checkov:skip=CKV_AWS_50: X-Ray tracing is not used anywhere in this stack (see the tfsec ignore above)
  s3_bucket        = var.bucket
  s3_key           = "lambda/mcp.zip"
  source_code_hash = data.aws_s3_object.mcp_hash.body
  function_name    = "mcp"
  role             = aws_iam_role.mcp.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  # Matches API Gateway's 29s integration timeout, like the call module.
  timeout = 29
  # get_message MIME-parses a whole message (same as fetch_message).
  memory_size = 512

  # Private-IMAP replumb: same VPC posture as the call-module endpoints.
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.mcp.name
  }

  # helper.py derives the IMAP host from these; this function is defined
  # outside the call module, so it carries its own copy (as append_sent does).
  environment {
    variables = {
      CONTROL_DOMAIN     = var.control_domain
      IMAP_INTERNAL_HOST = var.imap_internal_host
      IMAP_POOL_ENABLED  = var.imap_pool_enabled ? "true" : "false"
    }
  }

  # The role policy as well as the log group: CreateFunction validates that
  # the execution role can manage ENIs (vpc_config) at creation time (see the
  # call module's note on the 1.13.0 race).
  depends_on = [
    aws_cloudwatch_log_group.mcp,
    aws_iam_role_policy.mcp,
  ]

  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

resource "aws_lambda_permission" "mcp" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mcp.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "arn:aws:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.gateway.id}/*/*${aws_api_gateway_resource.mcp.path}"
}

# -- Route -------------------------------------------------------

resource "aws_api_gateway_resource" "mcp" {
  rest_api_id = aws_api_gateway_rest_api.gateway.id
  parent_id   = aws_api_gateway_rest_api.gateway.root_resource_id
  path_part   = "mcp"
}

# POST carries every JSON-RPC message. GET is routed too, only so the server
# can answer it 405 as the streamable-HTTP transport asks of a server that
# offers no server-initiated stream; without it API Gateway would answer a
# client's GET with its own 403. Both sit behind the agent authorizer.
resource "aws_api_gateway_method" "mcp" {
  #checkov:skip=CKV2_AWS_53:the body is JSON-RPC that the mcp Lambda parses and validates per method (bad JSON is answered -32700, bad params -32602); an API Gateway model could only restate the envelope and would turn those protocol errors into opaque 400s
  for_each      = toset(["POST", "GET"])
  rest_api_id   = aws_api_gateway_rest_api.gateway.id
  resource_id   = aws_api_gateway_resource.mcp.id
  http_method   = each.key
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.agent.id
}

resource "aws_api_gateway_integration" "mcp" {
  for_each                = aws_api_gateway_method.mcp
  rest_api_id             = aws_api_gateway_rest_api.gateway.id
  resource_id             = aws_api_gateway_resource.mcp.id
  http_method             = each.value.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.mcp.invoke_arn
}

locals {
  # Folded into aws_api_gateway_deployment's redeployment trigger in main.tf,
  # the same way the call module's hash_key output is.
  mcp_route_hash_key = jsonencode([
    aws_api_gateway_authorizer.agent,
    aws_api_gateway_resource.mcp,
    aws_api_gateway_method.mcp,
    aws_api_gateway_integration.mcp,
  ])
}
