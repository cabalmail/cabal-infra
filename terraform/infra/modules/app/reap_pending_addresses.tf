# Hourly reaper for expired pending (eagerly-created, never-confirmed)
# addresses (docs/1.x/browser-extension-plan.md, Phase 3.1.c): the floor
# under the browser extension's eager-create model. Revokes any address
# still pending past PENDING_TTL_HOURS -- the row, the shared DNS records
# (via helper's co-tenant-guarded teardown), and an SNS reconfigure event.
# Scheduled Lambda modeled on push_token_gc's EventBridge Scheduler wiring.

# -- IAM role for the reaper Lambda ------------------------------

resource "aws_iam_role" "reap_pending_addresses" {
  name = "reap_pending_addresses_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Sid       = "reapPendingAddressesSid"
      }
    ]
  })
}

resource "aws_iam_role_policy" "reap_pending_addresses" {
  name = "reap_pending_addresses_policy"
  role = aws_iam_role.reap_pending_addresses.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Scan",
          "dynamodb:GetItem",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/cabal-addresses"
      },
      {
        # The co-tenant-guarded DNS teardown (helper.teardown_address_dns_if_unused)
        # on the managed mail-domain zones, same trio of actions as the call module.
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:GetHostedZone",
          "route53:ListResourceRecordSets",
        ]
        Resource = [for domain in var.domains : domain.arn]
      },
      {
        # address_events.notify_containers, so the mail tiers drop reaped
        # addresses promptly.
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.address_changed_topic_arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
        ]
        Resource = "arn:aws:kms:${var.region}:${data.aws_caller_identity.current.account_id}:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "sns.${var.region}.amazonaws.com"
          }
        }
      },
      {
        # helper.py fetches /cabal/master_password once at module load; the
        # reaper imports helper for the shared DNS teardown, so the import
        # fails without this even though the reaper never opens IMAP.
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/master_password"
      },
      {
        # cloudwatch:PutMetricData has no resource-level scoping (metrics
        # are not ARN-addressable); the namespace condition below is the
        # tightest scoping CloudWatch offers.
        # iam-wildcard-ok: PutMetricData supports no resource ARNs - scoped by the cloudwatch:namespace condition instead
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "Cabalmail"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.reap_pending_addresses.arn}:*"
      }
    ]
  })
}

# -- Lambda function ---------------------------------------------

resource "aws_cloudwatch_log_group" "reap_pending_addresses" {
  name              = "/cabal/lambda/reap_pending_addresses"
  retention_in_days = 365
}

data "aws_s3_object" "reap_pending_addresses_hash" {
  bucket = var.bucket
  key    = "lambda/reap_pending_addresses.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "reap_pending_addresses" {
  # Same posture as push_token_gc:
  #checkov:skip=CKV_AWS_115: shared-pool concurrency is the point; a per-function reserve would starve the API lambdas
  #checkov:skip=CKV_AWS_116: scheduler-invoked housekeeping; a missed hourly run is retried next hour, a DLQ would only collect noise
  #checkov:skip=CKV_AWS_117: touches only AWS APIs; a VPC placement would add a NAT dependency for zero data-plane gain
  #checkov:skip=CKV_AWS_272: code-signing is not part of this repo's Lambda supply chain (zips are hash-pinned at build; see build-api-one.sh)
  #checkov:skip=CKV_AWS_50: X-Ray tracing is not used anywhere in this stack (see the tfsec ignore above)
  s3_bucket        = var.bucket
  s3_key           = "lambda/reap_pending_addresses.zip"
  source_code_hash = data.aws_s3_object.reap_pending_addresses_hash.body
  function_name    = "reap_pending_addresses"
  role             = aws_iam_role.reap_pending_addresses.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  # A full-table scan of a small table plus a handful of Route 53 calls;
  # generous headroom over the 29s API-lambda convention because nothing
  # user-facing waits on this.
  timeout     = 120
  memory_size = 128

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.reap_pending_addresses.name
  }

  environment {
    variables = {
      DOMAINS                   = jsonencode({ for r in var.domains : r.domain => r.zone_id })
      CONTROL_DOMAIN            = var.control_domain
      ADDRESS_CHANGED_TOPIC_ARN = var.address_changed_topic_arn
      # The abandonment window (docs/1.x/browser-extension-plan.md, open
      # question 5): long enough for the slowest legitimate form-fill, not
      # so long that abandoned addresses accumulate. Tunable without a
      # redeploy.
      PENDING_TTL_HOURS = "24"
    }
  }

  depends_on = [aws_cloudwatch_log_group.reap_pending_addresses]

  # Out-of-band Lambda deploys mutate code via aws lambda update-function-code;
  # ignore these so a topology-only Terraform apply does not roll the update
  # back (matches push_token_gc and the call module).
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

# -- Hourly schedule ---------------------------------------------

resource "aws_iam_role" "reap_pending_addresses_scheduler" {
  name = "cabal-reap-pending-addresses-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "scheduler.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy" "reap_pending_addresses_scheduler_invoke" {
  name = "cabal-reap-pending-addresses-scheduler-invoke"
  role = aws_iam_role.reap_pending_addresses_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.reap_pending_addresses.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "reap_pending_addresses" {
  name        = "cabal-reap-pending-addresses"
  description = "Revoke eagerly-created addresses still pending past the TTL (hourly)"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 15
  }

  schedule_expression = "rate(1 hour)"

  target {
    arn      = aws_lambda_function.reap_pending_addresses.arn
    role_arn = aws_iam_role.reap_pending_addresses_scheduler.arn
  }
}
