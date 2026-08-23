# Push-notification dispatch pipeline (docs/0.11.0/push-notifications.md,
# extended for Android by docs/1.x/android-push-notifications.md): the
# consumer Lambda for the wake-signal queue, its IAM, the event source
# mapping, and the SSM parameters holding the APNs and FCM credentials.
#
# The producer side (cabal-push-queue + DLQ, the imap task-role grant, and the
# PUSH_QUEUE_URL env var) lives in modules/ecs/push.tf next to the imap task
# definition. This consumer looks up the user's device tokens in
# cabal-push-tokens and sends one content-free wake signal per token — Apple
# rows via APNs, android rows via FCM; the device then calls /push_envelope
# to enrich the notification locally, so neither Apple's nor Google's
# infrastructure ever sees message content.

# -- APNs credentials --------------------------------------------
# Operator-populated after creating an APNs auth key in the Apple Developer
# portal (see docs/push-notifications.md for the runbook):
#   aws ssm put-parameter --name /cabal/apns/private_key \
#     --type SecureString --value file://AuthKey_XXXXXXXXXX.p8 --overwrite
# The dispatch Lambda treats the placeholder value as "not configured" and
# drops that platform's wake signals instead of retrying them into the DLQ,
# so environments without an APNs key (or with no Apple app installed) stay
# quiet. The same posture applies per-sender to the FCM credential below.

locals {
  # The "placeholder-" prefix is load-bearing: push_dispatch's function.py
  # (PLACEHOLDER_PREFIX) matches on it to decide the environment is not yet
  # provisioned. Keep the two in sync.
  push_placeholder = "placeholder-set-via-aws-ssm-put-parameter"
}

resource "aws_ssm_parameter" "apns_team_id" {
  name        = "/cabal/apns/team_id"
  description = "Apple Developer Team ID for APNs token auth. Populate via aws ssm put-parameter --overwrite."
  type        = "SecureString"
  value       = local.push_placeholder

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "apns_key_id" {
  name        = "/cabal/apns/key_id"
  description = "Key ID of the APNs auth key (.p8). Populate via aws ssm put-parameter --overwrite."
  type        = "SecureString"
  value       = local.push_placeholder

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "apns_private_key" {
  name        = "/cabal/apns/private_key"
  description = "APNs auth key (.p8 PEM content). High-value: rotate via the Apple Developer portal per docs/push-notifications.md. Populate via aws ssm put-parameter --overwrite."
  type        = "SecureString"
  value       = local.push_placeholder

  lifecycle {
    ignore_changes = [value]
  }
}

# Not a secret, but SecureString keeps the whole /cabal/apns/ namespace on one
# access pattern (GetParameter WithDecryption) and one Checkov posture.
resource "aws_ssm_parameter" "apns_endpoint" {
  name        = "/cabal/apns/endpoint"
  description = "APNs provider API base URL. Default is production; point non-prod at https://api.sandbox.push.apple.com when testing development-signed builds."
  type        = "SecureString"
  value       = "https://api.push.apple.com"

  lifecycle {
    ignore_changes = [value]
  }
}

# -- FCM credentials ---------------------------------------------
# Operator-populated after creating a Firebase project and a least-privilege
# service account (roles/firebasecloudmessaging.admin only — not the default
# firebase-adminsdk account) per docs/1.x/android-push-notifications.md:
#   aws ssm put-parameter --name /cabal/fcm/service_account \
#     --type SecureString --value file://cabal-fcm-<env>.json --overwrite

resource "aws_ssm_parameter" "fcm_service_account" {
  name        = "/cabal/fcm/service_account"
  description = "Google service-account JSON key for FCM HTTP v1 sends. High-value: rotate per docs/1.x/android-push-notifications.md. Populate via aws ssm put-parameter --overwrite."
  type        = "SecureString"
  value       = local.push_placeholder

  lifecycle {
    ignore_changes = [value]
  }
}

# -- IAM role for the dispatch Lambda ----------------------------

resource "aws_iam_role" "push_dispatch" {
  name = "push_dispatch_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Sid       = "pushDispatchSid"
      }
    ]
  })
}

resource "aws_iam_role_policy" "push_dispatch" {
  name = "push_dispatch_policy"
  role = aws_iam_role.push_dispatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetParametersByPath authorizes against the path itself as well as
        # the parameters under it, hence both resource forms.
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParametersByPath",
        ]
        Resource = [
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/apns",
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/apns/*",
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/fcm",
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/fcm/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/cabal-push-tokens"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = var.push_queue_arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.push_dispatch.arn}:*"
      }
    ]
  })
}

# -- Lambda function ---------------------------------------------

resource "aws_cloudwatch_log_group" "push_dispatch" {
  name              = "/cabal/lambda/push_dispatch"
  retention_in_days = 365
}

data "aws_s3_object" "push_dispatch_hash" {
  bucket = var.bucket
  key    = "lambda/push_dispatch.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "push_dispatch" {
  # Same posture as the append_sent consumer this function mirrors:
  #checkov:skip=CKV_AWS_115: shared-pool concurrency is the point; a per-function reserve would starve the API lambdas
  #checkov:skip=CKV_AWS_116: SQS is the trigger, so failed events redeliver and land in cabal-push-dlq; a Lambda-side DLQ is redundant here
  #checkov:skip=CKV_AWS_117: needs APNs and FCM (public internet) and only AWS APIs otherwise; a VPC placement would add a NAT dependency for zero data-plane gain
  #checkov:skip=CKV_AWS_272: code-signing is not part of this repo's Lambda supply chain (zips are hash-pinned at build; see build-api-one.sh)
  #checkov:skip=CKV_AWS_50: X-Ray tracing is not used anywhere in this stack (see the tfsec ignore above)
  s3_bucket        = var.bucket
  s3_key           = "lambda/push_dispatch.zip"
  source_code_hash = data.aws_s3_object.push_dispatch_hash.body
  function_name    = "push_dispatch"
  role             = aws_iam_role.push_dispatch.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 60
  memory_size      = 128

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.push_dispatch.name
  }

  environment {
    variables = {
      PUSH_TOKENS_TABLE_NAME = "cabal-push-tokens"
    }
  }

  depends_on = [aws_cloudwatch_log_group.push_dispatch]

  # Out-of-band Lambda deploys mutate code via aws lambda update-function-code;
  # ignore these so a topology-only Terraform apply does not roll the update
  # back (matches append_sent and the call module).
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

resource "aws_lambda_event_source_mapping" "push_dispatch" {
  event_source_arn = var.push_queue_arn
  function_name    = aws_lambda_function.push_dispatch.arn

  # One wake signal per invocation: a single failing dispatch (e.g. an APNs
  # outage mid-batch) retries on its own without re-sending its siblings'
  # already-delivered notifications.
  batch_size = 1
}
