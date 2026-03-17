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
  description = "Renew Let's Encrypt certificate every 60 days"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 60
  }

  schedule_expression = "rate(60 days)"

  target {
    arn      = aws_lambda_function.certbot.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}
