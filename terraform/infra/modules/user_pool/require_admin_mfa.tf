/**
* Pre-token-generation Cognito trigger that gates tokens on MFA
* enrollment (identity plan Phase 1; extended to all human users
* 2026-07). Two independently-flagged, audit-by-default gates:
* var.enforce_admin_mfa for admin-group members and
* var.enforce_user_mfa for everyone else (with a grace window from
* account creation so new signups can enroll first). In audit mode
* un-enrolled users are only logged ("would_block" lines in the
* Lambda's log group). Flip a gate to enforce ONLY after its
* population has enrolled TOTP: enrollment needs a signed-in session,
* so an enforced un-enrolled user cannot sign in to enroll and
* requires operator intervention.
*
* Bootstrap mirrors check_invite.tf: a placeholder zip is self-seeded on
* first apply so Terraform does not chicken-and-egg against app.yml, and
* the placeholder is a pure pass-through (tokens flow untouched until
* the real code ships out-of-band).
*/

data "archive_file" "require_admin_mfa_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.terraform/require_admin_mfa_placeholder.zip"
  source {
    content  = "def handler(event, _context):\n    return event\n"
    filename = "function.py"
  }
}

resource "aws_s3_object" "require_admin_mfa_zip" {
  bucket = var.bucket
  key    = "lambda/require_admin_mfa.zip"
  source = data.archive_file.require_admin_mfa_placeholder.output_path
  etag   = data.archive_file.require_admin_mfa_placeholder.output_md5

  lifecycle {
    ignore_changes = [source, etag, content, content_base64, source_hash, version_id, metadata]
  }
}

resource "aws_s3_object" "require_admin_mfa_hash" {
  bucket       = var.bucket
  key          = "/lambda/require_admin_mfa.zip.base64sha256"
  content      = data.archive_file.require_admin_mfa_placeholder.output_base64sha256
  content_type = "text/plain"

  lifecycle {
    ignore_changes = [content, etag, source, source_hash, version_id]
  }
}

resource "aws_iam_role" "require_admin_mfa" {
  name               = "require_admin_mfa"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "require_admin_mfa" {
  name = "require_admin_mfa_policy"
  role = aws_iam_role.require_admin_mfa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Reads UserMFASettingList for admin-group members only. Scoped
        # to this pool's ARN, matching the assign_osid narrowing.
        Effect   = "Allow"
        Action   = "cognito-idp:AdminGetUser"
        Resource = aws_cognito_user_pool.users.arn
      },
      {
        # Bare group ARN, no ":*" suffix: the log-group resource grammar
        # has no trailing segment (see counter.tf).
        Effect   = "Allow"
        Action   = "logs:CreateLogGroup"
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/require_admin_mfa"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          # iam-wildcard-ok: log-stream names are runtime-generated; the
          # group segment is pinned, the stream segment cannot be.
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/require_admin_mfa:${local.wildcard}",
        ]
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "require_admin_mfa" {
  name              = "/aws/lambda/require_admin_mfa"
  retention_in_days = 365
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "require_admin_mfa" {
  # Same posture as push_dispatch / push_token_gc:
  #checkov:skip=CKV_AWS_115: sign-in-rate Cognito trigger; a per-function reserve could throttle token issuance while starving the shared pool
  #checkov:skip=CKV_AWS_116: Cognito invokes its triggers synchronously; DLQs apply only to async invocation, so there is nothing to queue
  #checkov:skip=CKV_AWS_117: touches only the cognito-idp API; a VPC placement would add a NAT dependency for zero data-plane gain
  #checkov:skip=CKV_AWS_272: code-signing is not part of this repo's Lambda supply chain (zips are hash-pinned at build; see build-counter.sh)
  #checkov:skip=CKV_AWS_50: X-Ray tracing is not used anywhere in this stack (see the tfsec ignore above)
  s3_bucket        = aws_s3_object.require_admin_mfa_zip.bucket
  s3_key           = aws_s3_object.require_admin_mfa_zip.key
  source_code_hash = data.archive_file.require_admin_mfa_placeholder.output_base64sha256
  function_name    = "require_admin_mfa"
  role             = aws_iam_role.require_admin_mfa.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  # Cognito gives Lambda triggers 5 seconds; a longer timeout here would
  # only delay the retry Cognito performs anyway.
  timeout = 5

  depends_on = [
    aws_cloudwatch_log_group.require_admin_mfa,
    aws_s3_object.require_admin_mfa_zip,
  ]

  environment {
    variables = {
      ENFORCE_ADMIN_MFA = var.enforce_admin_mfa ? "true" : "false"
      ENFORCE_USER_MFA  = var.enforce_user_mfa ? "true" : "false"
      # Service and machine accounts that authenticate with a password
      # and can never enroll an authenticator. Verified against six
      # weeks of prod auth events (2026-07-23):
      # - master: SMTP submission identity for /send; authenticates on
      #   every outbound message.
      # - dmarc:  report-ingest mailbox (dmarc_user.tf); never signs in
      #   today, exempted defensively.
      # A short-lived App Store review demo account ("apple") was also a
      # candidate; it is deleted. Re-add a demo account here for the
      # duration of any future App Review cycle - reviewers need static
      # credentials and their sign-ins score high-risk.
      EXEMPT_USERS = "master,dmarc"
      # A new signup gets this long to sign in and enroll via the
      # Security page before the user gate applies to them.
      GRACE_HOURS = "48"
    }
  }

  # Matches the assign_osid pattern: out-of-band Lambda deploys mutate
  # code via aws lambda update-function-code; ignore those attributes
  # so a topology-only Terraform apply does not roll the update back.
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

resource "aws_lambda_permission" "allow_cognito_require_admin_mfa" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.require_admin_mfa.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.users.arn
}
