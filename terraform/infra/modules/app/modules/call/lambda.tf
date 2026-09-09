locals {
  hosted_zone_arns = join(",", [for domain in var.domains : "\"${domain.arn}\""])
  wildcard         = "*"

  # Every endpoint reads and writes the raw-message cache; only the endpoints
  # that retire a cached body (expunge, purge, draft replacement) also delete.
  cache_object_actions = join(",\n", [
    for action in concat(
      ["s3:PutObject", "s3:GetObject"],
      var.deletes_cache_objects ? ["s3:DeleteObject"] : []
    ) : "              \"${action}\""
  ])

  # RSS reader grants (phase 3), rendered into the heredoc below only for the
  # rss_* endpoints. Tables plus their indexes: the endpoints Query the
  # by_canonical, by_fetched, and favorite_by_feed indexes. The index glob
  # (table/<name>/index/*) covers the named table's own indexes only.
  # iam-wildcard-ok: per-table index glob - the table name is fixed, only its index names vary
  rss_tables = ["cabal-rss-feed", "cabal-rss-item", "cabal-rss-subscription",
  "cabal-rss-folder", "cabal-rss-user-item-state"]
  # iam-wildcard-ok: per-table index glob, see above
  rss_table_resources = var.rss_access ? join("", [
    for table in local.rss_tables :
    ",\n                \"arn:aws:dynamodb:${var.region}:${var.account}:table/${table}\",\n                \"arn:aws:dynamodb:${var.region}:${var.account}:table/${table}/index/${local.wildcard}\""
  ]) : ""
  # Spilled item bodies are keyed items/<feed_id>/<item_id> - runtime
  # values with no enumerable ARN, same as the message-cache object keys.
  # iam-wildcard-ok: runtime-only S3 object keys under the items/ prefix
  rss_statements_body = <<RSS
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::${var.rss_cache_bucket}/items/${local.wildcard}"
        },
        {
            "Effect": "Allow",
            "Action": "sqs:SendMessage",
            "Resource": "${var.rss_fetch_queue_arn}"
        },
RSS
  rss_statements      = var.rss_access ? local.rss_statements_body : ""
}

resource "aws_lambda_permission" "api_exec" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_call.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn = join("", [
    join(":", [
      "arn:aws:execute-api",
      var.region,
      var.account,
      var.gateway_id
    ]),
    "/*/",
    aws_api_gateway_method.api_call.http_method,
    aws_api_gateway_resource.api_call.path
  ])
}

resource "aws_iam_role" "lambda" {
  name = "${var.name}_role"

  assume_role_policy = <<ROLEPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": "${replace(var.name, "_", "")}Sid"
    }
  ]
}
ROLEPOLICY
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.name}_policy"
  role = aws_iam_role.lambda.id
  # Heredoc JSON cannot carry inline comments, so one directive covers every
  # wildcard in the document below: S3 object keys under the per-user cache
  # prefix and log-stream names are runtime values with no enumerable ARN,
  # and the EC2 ENI actions (VPC-attached Lambda networking) manage
  # Lambda-created interfaces whose ARNs likewise only exist at runtime,
  # with no resource-level scoping on Describe* at all (the statement
  # mirrors the AWSLambdaVPCAccessExecutionRole managed policy). Every
  # other statement names specific resources.
  # The RSS index wildcard (table/<name>/index/*) covers the named table's
  # own indexes only; per-index ARNs would restate the schema here.
  # iam-wildcard-ok: runtime-only ARNs (cache object keys, log streams, Lambda-managed ENIs, RSS spill keys) and per-table index globs - see above
  policy = <<RUNPOLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ssm:DescribeParameters"
            ],
            "Resource": "arn:aws:ssm:${var.region}:${var.account}:*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter"
            ],
            "Resource": [
                "arn:aws:ssm:${var.region}:${var.account}:parameter/cabal/master_password",
                "arn:aws:ssm:${var.region}:${var.account}:parameter/cabal/maintenance/imap"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
              "s3:ListBucket"
            ],
            "Resource": "arn:aws:s3:::cache.${var.control_domain}"
        },
        {
            "Effect": "Allow",
            "Action": [
${local.cache_object_actions}
            ],
            "Resource": "arn:aws:s3:::cache.${var.control_domain}/${local.wildcard}"
        },
        {
            "Effect": "Allow",
            "Action": [
              "route53:ChangeResourceRecordSets",
              "route53:GetHostedZone",
              "route53:ListResourceRecordSets"
            ],
            "Resource": [
              ${local.hosted_zone_arns}
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": [
                "${aws_cloudwatch_log_group.lambda_log.arn}:${local.wildcard}"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:BatchGetItem",
                "dynamodb:DeleteItem",
                "dynamodb:DescribeTable",
                "dynamodb:GetItem",
                "dynamodb:ListTables",
                "dynamodb:Query",
                "dynamodb:Scan",
                "dynamodb:PutItem",
                "dynamodb:UpdateItem",
                "dynamodb:ListTagsOfResource",
                "dynamodb:ListGlobalTables",
                "dynamodb:DescribeGlobalTable"
            ],
            "Resource": [
                "arn:aws:dynamodb:${var.region}:${var.account}:table/cabal-addresses",
                "arn:aws:dynamodb:${var.region}:${var.account}:table/cabal-dmarc-reports",
                "arn:aws:dynamodb:${var.region}:${var.account}:table/cabal-caa-reports",
                "arn:aws:dynamodb:${var.region}:${var.account}:table/cabal-user-preferences",
                "arn:aws:dynamodb:${var.region}:${var.account}:table/cabal-user-domain-access",
                "arn:aws:dynamodb:${var.region}:${var.account}:table/cabal-rate-limits",
                "arn:aws:dynamodb:${var.region}:${var.account}:table/cabal-push-tokens",
                "arn:aws:dynamodb:${var.region}:${var.account}:table/cabal-user-rules",
                "arn:aws:dynamodb:${var.region}:${var.account}:table/cabal-user-rules-audit"${local.rss_table_resources}
            ]
        },
${local.rss_statements}
        {
            "Effect": "Allow",
            "Action": "sns:Publish",
            "Resource": [
                "${var.address_changed_topic_arn}",
                "${var.user_rules_topic_arn}"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "kms:GenerateDataKey",
                "kms:Decrypt"
            ],
            "Resource": "arn:aws:kms:${var.region}:${var.account}:key/*",
            "Condition": {
                "StringEquals": {
                    "kms:ViaService": "sns.${var.region}.amazonaws.com"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "sqs:SendMessage",
                "sqs:GetQueueUrl"
            ],
            "Resource": "arn:aws:sqs:${var.region}:${var.account}:cabal-append-sent"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateNetworkInterface",
                "ec2:DescribeNetworkInterfaces",
                "ec2:DeleteNetworkInterface",
                "ec2:AssignPrivateIpAddresses",
                "ec2:UnassignPrivateIpAddresses"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "cognito-idp:ListUsers",
                "cognito-idp:AdminGetUser",
                "cognito-idp:AdminConfirmSignUp",
                "cognito-idp:AdminDisableUser",
                "cognito-idp:AdminEnableUser",
                "cognito-idp:AdminDeleteUser"
            ],
            "Resource": "arn:aws:cognito-idp:${var.region}:${var.account}:userpool/${var.user_pool_id}"
        }
    ]
}
RUNPOLICY
}

resource "aws_cloudwatch_log_group" "lambda_log" {
  name              = "/cabal/lambda/${var.name}"
  retention_in_days = 365
}

data "aws_s3_object" "lambda_function_hash" {
  bucket = var.bucket
  key    = "lambda/${var.name}.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "api_call" {
  s3_bucket        = var.bucket
  s3_key           = "lambda/${var.name}.zip"
  source_code_hash = data.aws_s3_object.lambda_function_hash.body
  function_name    = var.name
  role             = aws_iam_role.lambda.arn
  handler          = "function.handler"
  runtime          = var.runtime
  architectures    = [var.architecture]
  # 29s matches API Gateway's 29s integration timeout, so the Lambda stops
  # at the same boundary the client sees the request fail instead of billing
  # on invisibly past it (and a real timeout becomes an alarmable signal).
  timeout     = 29
  memory_size = var.memory

  # Private-IMAP replumb: run inside the VPC so IMAP consumers can reach the
  # imap task over its Cloud Map name. AWS-API and internet egress rides the
  # NAT path plus the S3/DynamoDB gateway endpoints (modules/vpc/endpoints.tf).
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda_log.name
  }
  environment {
    variables = {
      DOMAINS                     = jsonencode({ for r in var.domains : r.domain => r.zone_id })
      CONTROL_DOMAIN              = var.control_domain
      ADDRESS_CHANGED_TOPIC_ARN   = var.address_changed_topic_arn
      USER_POOL_ID                = var.user_pool_id
      DMARC_TABLE_NAME            = "cabal-dmarc-reports"
      CAA_TABLE_NAME              = "cabal-caa-reports"
      USER_PREFERENCES_TABLE_NAME = "cabal-user-preferences"
      USER_RULES_TABLE_NAME       = "cabal-user-rules"
      USER_RULES_AUDIT_TABLE_NAME = "cabal-user-rules-audit"
      USER_RULES_TOPIC_ARN        = var.user_rules_topic_arn
      PUSH_TOKENS_TABLE_NAME      = "cabal-push-tokens"
      IMAP_POOL_ENABLED           = var.imap_pool_enabled ? "true" : "false"
      IMAP_INTERNAL_HOST          = var.imap_internal_host
      SMTP_INTERNAL_HOST          = var.smtp_internal_host
      RSS_FETCH_QUEUE_URL         = var.rss_access ? var.rss_fetch_queue_url : ""
      RSS_CACHE_BUCKET            = var.rss_access ? var.rss_cache_bucket : ""
    }
  }
  depends_on = [
    aws_cloudwatch_log_group.lambda_log,
  ]
  # Phase 2 of docs/0.9.x/build-deploy-simplification-plan.md.
  # Out-of-band Lambda deploys will mutate code via aws lambda
  # update-function-code; ignoring these attributes prevents a
  # topology-only Terraform apply from rolling that update back.
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}
