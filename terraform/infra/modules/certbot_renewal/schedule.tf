resource "aws_iam_role" "scheduler" {
  name = "cabal-certbot-renewal-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name = "invoke-certbot-lambda"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.certbot.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "certbot" {
  name        = "cabal-certbot-renewal"
  description = "Daily check; renews the Let's Encrypt certificate once half its lifetime has passed"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 60
  }

  # Daily so a failed issuance is retried the next day. The Lambda itself
  # decides whether renewal is due (see RENEW_FRACTION in handler.py), which
  # keeps it correct as Let's Encrypt shortens lifetimes to 64 and then 45
  # days.
  schedule_expression = "rate(1 day)"

  target {
    arn      = aws_lambda_function.certbot.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}
