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

# API gateway for admin application
resource "aws_api_gateway_rest_api" "gateway" {
  name = "cabal_gateway"
}

# API calls must be authorized via Cognito
resource "aws_api_gateway_authorizer" "api_auth" {
  name        = "cabal_pool"
  rest_api_id = aws_api_gateway_rest_api.gateway.id
  type        = "COGNITO_USER_POOLS"
  # Cap how long API Gateway trusts a cached authorizer result. At the default
  # 300s a token revoked in Cognito stays usable against the API for up to five
  # minutes; 60s bounds that window to one minute.
  authorizer_result_ttl_in_seconds = 60
  provider_arns = [join("", [
    "arn:aws:cognito-idp:",
    var.region,
    ":",
    data.aws_caller_identity.current.account_id,
    ":userpool/",
    var.user_pool_id
  ])]
}

module "cabal_method" {
  for_each                  = local.lambdas
  source                    = "./modules/call"
  name                      = each.key
  runtime                   = each.value.runtime
  method                    = each.value.method
  memory                    = each.value.memory
  region                    = var.region
  account                   = data.aws_caller_identity.current.account_id
  gateway_id                = aws_api_gateway_rest_api.gateway.id
  root_resource_id          = aws_api_gateway_rest_api.gateway.root_resource_id
  authorizer                = aws_api_gateway_authorizer.api_auth.id
  control_domain            = var.control_domain
  domains                   = var.domains
  bucket                    = var.bucket
  address_changed_topic_arn = var.address_changed_topic_arn
  user_pool_id              = var.user_pool_id
  # Alarm on tail latency/errors for the endpoints whose latency tracks folder
  # cardinality (large-mailbox hardening plan, Layer 4.3).
  alarm_on_latency  = contains(["list_messages", "list_envelopes"], each.key)
  imap_pool_enabled = var.imap_pool_enabled
  # Endpoints that expunge a message (or replace a draft) also drop its cached
  # raw body, so the expunged copy stays unreadable through fetch_message.
  deletes_cache_objects = contains(["send", "save_draft", "purge_messages", "empty_trash"], each.key)

  # Private-IMAP replumb: every endpoint runs inside the VPC (uniform posture;
  # the DynamoDB-only functions ride along) and IMAP consumers dial the imap
  # task via Cloud Map instead of the public IMAPS listener.
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.lambda.id]
  imap_internal_host = var.imap_internal_host
  smtp_internal_host = var.smtp_internal_host
  # fetch_bimi bundles a static resvg binary that ships only for linux-x86_64,
  # so it runs x86_64 while the rest of the API fleet stays arm64.
  architecture = each.key == "fetch_bimi" ? "x86_64" : "arm64"
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

# API Gateway's execution log. The name is AWS's, not ours - the service
# writes to API-Gateway-Execution-Logs_<rest-api-id>/<stage> and nowhere else -
# so this group cannot be renamed, moved or split after the fact. Declaring it
# here is what puts a retention on it; left to the service it would be created
# on first write and never expire.
#
# Thirty days, not the 365 every other group in this stack carries: this is the
# group #1233 is about. While #1223's method settings resolved to INFO with data
# tracing on, the service wrote truncated request/response bodies, truncated
# Authorization headers and complete JWT claims here, and retention on this
# group is the only lever that ages that history out. The window it ages out is
# fixed - the oldest retrievable event in either account is 2026-06-29, left
# behind when 4d1e8f3e raised this group from 14 days to 365 - so 30 days
# retires all of it within a month and nothing new joins it now that #1223 has
# applied. Collateral, accepted deliberately: the access-log entries written
# before the split above still live in this group and go with the bodies.
resource "aws_cloudwatch_log_group" "api_logs" {
  #checkov:skip=CKV_AWS_338:Thirty days is the decision recorded in #1233, not an oversight. This group is the one place request/response bodies and truncated Authorization headers landed while #1223's method settings were misresolved; a year of retention is a year of that history. ERROR-level execution logs are a debugging aid with a short half-life, so the forensic value the one-year floor protects is not the value this particular group carries. Every other log group in the stack keeps 365.
  name              = "API-Gateway-Execution-Logs_${aws_api_gateway_rest_api.gateway.id}/${var.stage_name}"
  retention_in_days = 30
}

# The access log is a group of its own, and that separation is the point.
#
# Until #1233 the stage's access log was written into `api_logs` above, so the
# two signals could not be retained apart. They want different answers: the
# access log is the per-request record worth keeping, while the execution log
# is where #1223's misresolved method settings put request and response bodies
# and truncated Authorization headers for ~8 weeks. The only lever for ageing
# that history out is retention on its group, and while the groups were shared
# that lever took the access log with it.
#
# Nothing moves. Entries written before this applies stay in the group that
# received them, so the pre-split access-log history lives on in `api_logs` and
# ages out on its 30 days. Everything written here keeps the year.
resource "aws_cloudwatch_log_group" "api_access_logs" {
  name              = "/cabal/apigateway/access/${aws_api_gateway_rest_api.gateway.id}/${var.stage_name}"
  retention_in_days = 365
}

#tfsec:ignore:aws-api-gateway-enable-tracing
resource "aws_api_gateway_stage" "api_stage" {
  deployment_id         = aws_api_gateway_deployment.deployment.id
  rest_api_id           = aws_api_gateway_rest_api.gateway.id
  stage_name            = var.stage_name
  cache_cluster_enabled = false
  cache_cluster_size    = "0.5"
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access_logs.arn
    format          = "{ \"requestId\":\"$context.requestId\", \"extendedRequestId\":\"$context.extendedRequestId\",\"ip\": \"$context.identity.sourceIp\", \"caller\":\"$context.identity.caller\", \"user\":\"$context.identity.user\", \"requestTime\":\"$context.requestTime\", \"httpMethod\":\"$context.httpMethod\", \"resourcePath\":\"$context.resourcePath\", \"status\":\"$context.status\", \"protocol\":\"$context.protocol\", \"responseLength\":\"$context.responseLength\" }"
  }
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
      "Resource": "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*:*"
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
    # The three observability fields are shared with `cache_settings` below -
    # see the comment on `local.method_observability`.
    metrics_enabled        = local.method_observability.metrics_enabled
    data_trace_enabled     = local.method_observability.data_trace_enabled
    logging_level          = local.method_observability.logging_level
    throttling_rate_limit  = 100
    throttling_burst_limit = 50
  }
  depends_on = [aws_api_gateway_account.apigw_account]
}

resource "aws_api_gateway_method_settings" "cache_settings" {
  for_each    = local.lambdas
  rest_api_id = aws_api_gateway_rest_api.gateway.id
  stage_name  = aws_api_gateway_stage.api_stage.stage_name
  method_path = "${each.key}/${each.value.method}"
  settings {
    caching_enabled      = each.value.cache
    cache_ttl_in_seconds = each.value.cache_ttl
    # Restated, not inherited: a per-method entry replaces the `*/*` defaults
    # wholesale, so leaving these out hands the method API Gateway's own
    # defaults instead (#1223).
    metrics_enabled    = local.method_observability.metrics_enabled
    data_trace_enabled = local.method_observability.data_trace_enabled
    logging_level      = local.method_observability.logging_level
  }
}
