# RSS fetch pipeline (docs/1.x/rss-implementation-plan.md, phase 2): the
# scheduler Lambda that claims due feeds every five minutes, the fetch
# worker that consumes cabal-rss-fetch-queue (modules/app/rss.tf) one feed
# per invocation, their IAM, log groups, the EventBridge Scheduler schedule,
# and the operator-tunable cadence bounds in SSM. The tables live in
# modules/table (phase 1).
#
# Both functions are VPC-attached like every other Lambda in this module.
# For the fetcher that is load-bearing: its outbound requests to publishers
# leave through the NAT Elastic IPs (docs/nat.md), the stack's only stable
# egress identity - what a publisher sees in its logs and what the feedbot
# page (front-door/feedbot.html) tells them to expect. A Lambda outside the
# VPC would fetch from AWS's shared, rotating pool instead.

# -- Cadence bounds ----------------------------------------------
# The adaptive cadence (D17) stays inside [min, max] minutes. SecureString
# for the same reason as /cabal/apns/endpoint: not secrets, but one access
# pattern and one Checkov posture for every parameter under /cabal/.
# Operator override: aws ssm put-parameter --overwrite; the worker re-reads
# every five minutes, no redeploy.

resource "aws_ssm_parameter" "rss_cadence_min" {
  name        = "/cabal/rss/cadence_min_minutes"
  description = "Floor on the RSS fetcher's per-feed cadence, in minutes. Never fetch a feed more often than this."
  type        = "SecureString"
  value       = "15"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "rss_cadence_max" {
  name        = "/cabal/rss/cadence_max_minutes"
  description = "Ceiling on the RSS fetcher's per-feed cadence, in minutes. A quiet feed is still fetched at least this often."
  type        = "SecureString"
  value       = "1440"

  lifecycle {
    ignore_changes = [value]
  }
}

# -- Scheduler Lambda --------------------------------------------

resource "aws_iam_role" "rss_schedule" {
  name = "rss_schedule_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Sid       = "rssScheduleSid"
      }
    ]
  })
}

resource "aws_iam_role_policy" "rss_schedule" {
  #checkov:skip=CKV_AWS_290:the only unconstrained write actions are the EC2 ENI trio for VPC-attached Lambda networking - Lambda-managed interface ARNs only exist at runtime (mirrors AWSLambdaVPCAccessExecutionRole)
  #checkov:skip=CKV_AWS_355:same statement - ec2:Describe* has no resource-level scoping and the ENI create/delete targets are runtime values
  name = "rss_schedule_policy"
  role = aws_iam_role.rss_schedule.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Query the sparse by_due index, then claim each due row.
        Effect   = "Allow"
        Action   = "dynamodb:Query"
        Resource = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/cabal-rss-feed/index/by_due"
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/cabal-rss-feed"
      },
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.rss_fetch.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.rss_schedule.arn}:*"
      },
      {
        # iam-wildcard-ok: EC2 ENI actions for VPC-attached Lambda networking.
        # Lambda-created interface ARNs only exist at runtime and Describe*
        # has no resource-level scoping; mirrors AWSLambdaVPCAccessExecutionRole.
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

resource "aws_cloudwatch_log_group" "rss_schedule" {
  name              = "/cabal/lambda/rss_schedule"
  retention_in_days = 365
}

data "aws_s3_object" "rss_schedule_hash" {
  bucket = var.bucket
  key    = "lambda/rss_schedule.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "rss_schedule" {
  #checkov:skip=CKV_AWS_115:shared-pool concurrency is the point for a five-minute tick that runs alone; a reserve would only starve the API lambdas
  #checkov:skip=CKV_AWS_116:scheduler-invoked; a missed tick is retried by the next one five minutes later and the claim lease makes the retry idempotent, so a DLQ would only collect noise
  #checkov:skip=CKV_AWS_272:code-signing is not part of this repo's Lambda supply chain (zips are hash-pinned at build; see build-api-one.sh)
  #checkov:skip=CKV_AWS_50:X-Ray tracing is not used anywhere in this stack (see the tfsec ignore above)
  s3_bucket        = var.bucket
  s3_key           = "lambda/rss_schedule.zip"
  source_code_hash = data.aws_s3_object.rss_schedule_hash.body
  function_name    = "rss_schedule"
  role             = aws_iam_role.rss_schedule.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  # One index Query plus one conditional update and one SQS send per due
  # feed; hundreds of feeds fit comfortably.
  timeout     = 60
  memory_size = 128

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.rss_schedule.name
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      FETCH_QUEUE_URL = aws_sqs_queue.rss_fetch.url
      # A claim outlives the worker's timeout plus the queue's visibility
      # window, so a live fetch is never re-enqueued; a lost message costs
      # one lease, not a day.
      CLAIM_LEASE_MINUTES = "30"
      MAX_FEEDS_PER_TICK  = "500"
    }
  }

  # Policy before function: see the call module's note on CreateFunction's
  # ENI-permission check.
  depends_on = [aws_cloudwatch_log_group.rss_schedule, aws_iam_role_policy.rss_schedule]

  # Out-of-band Lambda deploys mutate code via aws lambda update-function-code;
  # ignore these so a topology-only Terraform apply does not roll the update
  # back (matches reap_pending_addresses and the call module).
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

# -- Fetch worker --------------------------------------------------

resource "aws_iam_role" "rss_fetch" {
  name = "rss_fetch_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Sid       = "rssFetchSid"
      }
    ]
  })
}

resource "aws_iam_role_policy" "rss_fetch" {
  #checkov:skip=CKV_AWS_290:the only unconstrained write actions are the EC2 ENI trio for VPC-attached Lambda networking - Lambda-managed interface ARNs only exist at runtime (mirrors AWSLambdaVPCAccessExecutionRole)
  #checkov:skip=CKV_AWS_355:same statement - ec2:Describe* has no resource-level scoping and the ENI create/delete targets are runtime values
  name = "rss_fetch_policy"
  role = aws_iam_role.rss_fetch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read the claimed feed row and write its health/cadence; look up a
        # permanent-redirect target on by_canonical before following it.
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
        ]
        Resource = [
          "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/cabal-rss-feed",
          "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/cabal-rss-feed/index/by_canonical",
        ]
      },
      {
        # Upsert items: by_guid lookup, conditional Put for new, Update for changed.
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
        ]
        Resource = [
          "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/cabal-rss-item",
          "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/cabal-rss-item/index/by_guid",
        ]
      },
      {
        # Bodies too large for a DynamoDB row spill to the items/ prefix only.
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.rss_cache.arn}/items/*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.rss_fetch.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
        ]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/rss/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.rss_fetch.arn}:*"
      },
      {
        # iam-wildcard-ok: EC2 ENI actions for VPC-attached Lambda networking.
        # Lambda-created interface ARNs only exist at runtime and Describe*
        # has no resource-level scoping; mirrors AWSLambdaVPCAccessExecutionRole.
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

resource "aws_cloudwatch_log_group" "rss_fetch" {
  name              = "/cabal/lambda/rss_fetch"
  retention_in_days = 365
}

data "aws_s3_object" "rss_fetch_hash" {
  bucket = var.bucket
  key    = "lambda/rss_fetch.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "rss_fetch" {
  #checkov:skip=CKV_AWS_116:failures land in cabal-rss-fetch-dlq through the source queue's redrive policy (modules/app/rss.tf); a function-level DLQ would duplicate it
  #checkov:skip=CKV_AWS_272:code-signing is not part of this repo's Lambda supply chain (zips are hash-pinned at build; see build-api-one.sh)
  #checkov:skip=CKV_AWS_50:X-Ray tracing is not used anywhere in this stack (see the tfsec ignore above)
  s3_bucket        = var.bucket
  s3_key           = "lambda/rss_fetch.zip"
  source_code_hash = data.aws_s3_object.rss_fetch_hash.body
  function_name    = "rss_fetch"
  role             = aws_iam_role.rss_fetch.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  # One publisher round trip (hard 20s/60s caps in rss_http) plus up to
  # 500 item upserts; the queue's 180s visibility timeout sits above this.
  timeout     = 120
  memory_size = 512
  # Politeness and blast radius: at most this many publisher connections
  # at once, however many feeds come due together. The event source
  # mapping's maximum_concurrency below says the same thing from the
  # queue's side.
  reserved_concurrent_executions = 5

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.rss_fetch.name
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      CONTROL_DOMAIN       = var.control_domain
      RSS_CACHE_BUCKET     = aws_s3_bucket.rss_cache.bucket
      DEAD_LETTER_FAILURES = "20"
      # Bodies over this many bytes spill to S3 (DynamoDB caps an item at
      # 400 KB; the rest of the row needs headroom).
      SPILL_BYTES = "300000"
    }
  }

  depends_on = [aws_cloudwatch_log_group.rss_fetch, aws_iam_role_policy.rss_fetch]

  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

resource "aws_lambda_event_source_mapping" "rss_fetch" {
  event_source_arn = aws_sqs_queue.rss_fetch.arn
  function_name    = aws_lambda_function.rss_fetch.arn

  # One feed per invocation: a failing feed retries alone and never
  # re-fetches its batch-mates.
  batch_size = 1

  scaling_config {
    maximum_concurrency = 5
  }
}

# -- Five-minute tick ----------------------------------------------

resource "aws_iam_role" "rss_schedule_scheduler" {
  name = "cabal-rss-schedule-scheduler"

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

resource "aws_iam_role_policy" "rss_schedule_scheduler_invoke" {
  name = "cabal-rss-schedule-scheduler-invoke"
  role = aws_iam_role.rss_schedule_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.rss_schedule.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "rss_schedule" {
  name        = "cabal-rss-schedule"
  description = "Claim due RSS feeds and enqueue them for fetching (every five minutes)"

  # Quiesce (docs/quiesce.md) removes the private subnets' default route, so
  # a tick in a quiesced environment would only enqueue feeds the worker
  # cannot reach until the DLQ fills. The same variable that scales compute
  # to zero pauses the tick.
  state = var.quiesced ? "DISABLED" : "ENABLED"

  # OFF, not FLEXIBLE: per-feed cadence is computed from wall-clock
  # next_fetch_at values, and a jittered tick would blur the minimum
  # cadence the operator set.
  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(5 minutes)"

  target {
    arn      = aws_lambda_function.rss_schedule.arn
    role_arn = aws_iam_role.rss_schedule_scheduler.arn
  }
}
