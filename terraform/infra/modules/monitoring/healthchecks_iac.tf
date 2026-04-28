# ── Phase 4 §3: healthchecks_iac Lambda ────────────────────────
#
# Reconciles Healthchecks check definitions from
# lambda/api/healthchecks_iac/config.py against the running
# Healthchecks instance. Replaces the manual "Phase 2 setup footgun"
# (operator hand-creating six checks in the UI and pasting six ping
# URLs into SSM).
#
# Reach the Healthchecks API on the private Cloud Map A record
# (healthchecks.cabal-monitoring.cabal.internal:8000) — bypasses the
# Cognito-fronted public ALB. The API key in SSM is sufficient auth.
#
# Why no Kuma equivalent: Kuma exposes only a Socket.IO API in this
# release, not REST. Building IaC around Socket.IO is fragile across
# version upgrades and offers little value for the eight Phase 1
# monitors. Kuma config stays manual; see docs/monitoring.md §27 for
# the deferral rationale.

data "aws_s3_object" "healthchecks_iac_hash" {
  bucket = var.lambda_bucket
  key    = "lambda/healthchecks_iac.zip.base64sha256"
}

resource "aws_iam_role" "healthchecks_iac" {
  name = "healthchecks_iac_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# VPC ENI management for the Lambda (since it runs in private subnets
# to reach the Healthchecks task via Cloud Map).
resource "aws_iam_role_policy_attachment" "healthchecks_iac_vpc" {
  role       = aws_iam_role.healthchecks_iac.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "healthchecks_iac" {
  name = "healthchecks_iac_policy"
  role = aws_iam_role.healthchecks_iac.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read the API key + ping URLs (the Lambda checks before write
        # to avoid SSM version churn).
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = concat(
          [aws_ssm_parameter.healthchecks_api_key.arn],
          [for k, v in aws_ssm_parameter.healthcheck_ping : v.arn],
        )
      },
      {
        # Write ping URLs after each upsert.
        Effect = "Allow"
        Action = ["ssm:PutParameter"]
        Resource = [
          for k, v in aws_ssm_parameter.healthcheck_ping : v.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/cabal/lambda/healthchecks_iac:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "healthchecks_iac" {
  name              = "/cabal/lambda/healthchecks_iac"
  retention_in_days = 14
}

# Lambda lives in private subnets so the Cloud Map A record for
# Healthchecks resolves and the SG-to-SG rule applies. Egress only.
resource "aws_security_group" "healthchecks_iac" {
  name        = "cabal-healthchecks-iac"
  description = "healthchecks_iac Lambda — reaches the Healthchecks API on the private Cloud Map name."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "healthchecks_iac_to_healthchecks" {
  type                     = "egress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.healthchecks.id
  security_group_id        = aws_security_group.healthchecks_iac.id
  description              = "Lambda to Healthchecks task on the API port."
}

# DNS resolution to AWS endpoints (SSM, CloudWatch Logs) and to
# Cloud Map. Cloud Map private DNS uses Route 53 Resolver, which is
# reachable inside the VPC over the standard 53/udp.
resource "aws_security_group_rule" "healthchecks_iac_dns_udp" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [var.vpc_cidr_block]
  security_group_id = aws_security_group.healthchecks_iac.id
  description       = "VPC Resolver for Cloud Map name lookups."
}

# HTTPS egress for SSM, CloudWatch Logs (no VPC endpoints in this
# stack today). 0.0.0.0/0 because the AWS regional endpoints don't
# have static prefix lists per service we'd want to enumerate here.
resource "aws_security_group_rule" "healthchecks_iac_https_out" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.healthchecks_iac.id
  description       = "Outbound HTTPS for SSM and CloudWatch Logs API calls."
}

# Inbound rule on the Healthchecks SG to accept the Lambda. Defined
# here so it lives next to the Lambda; the inverse-direction rule on
# the Lambda's SG is above. SG-to-SG references work whichever side
# defines them.
resource "aws_security_group_rule" "healthchecks_from_iac_lambda" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.healthchecks_iac.id
  security_group_id        = aws_security_group.healthchecks.id
  description              = "Healthchecks accepts API calls from the healthchecks_iac Lambda."
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "healthchecks_iac" {
  s3_bucket        = var.lambda_bucket
  s3_key           = "lambda/healthchecks_iac.zip"
  source_code_hash = data.aws_s3_object.healthchecks_iac_hash.body
  function_name    = "cabal-healthchecks-iac"
  role             = aws_iam_role.healthchecks_iac.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 60
  memory_size      = 128

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.healthchecks_iac.name
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.healthchecks_iac.id]
  }

  environment {
    variables = {
      HEALTHCHECKS_API_KEY_PARAM = aws_ssm_parameter.healthchecks_api_key.name
      # Cloud Map's private DNS resolves from the Lambda's VPC ENI.
      # Port 8000 matches the Healthchecks task port.
      HEALTHCHECKS_BASE_URL = "http://healthchecks.cabal-monitoring.cabal.internal:8000"
    }
  }

  depends_on = [aws_cloudwatch_log_group.healthchecks_iac]
}

# Auto-invoke on every plan/apply when the Lambda zip changes (i.e.
# when config.py is edited and the build pipeline rebuilds). The
# Lambda no-ops when the API key is still placeholder, so the first
# apply doesn't fail before the operator has bootstrapped the key.
#
# `lifecycle_scope = "CRUD"` re-invokes on triggers change AND on
# destroy; we want the invoke-on-update behavior.
resource "aws_lambda_invocation" "healthchecks_iac" {
  function_name = aws_lambda_function.healthchecks_iac.function_name
  input         = jsonencode({})

  lifecycle_scope = "CRUD"

  triggers = {
    source_code_hash = aws_lambda_function.healthchecks_iac.source_code_hash
  }

  depends_on = [
    aws_ecs_service.healthchecks,
    aws_service_discovery_service.monitoring,
  ]
}
