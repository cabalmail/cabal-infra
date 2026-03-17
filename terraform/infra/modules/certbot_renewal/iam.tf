data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  ssm_parameter_arns = [
    "arn:aws:ssm:${var.region}:${local.account_id}:parameter/cabal/control_domain_ssl_key",
    "arn:aws:ssm:${var.region}:${local.account_id}:parameter/cabal/control_domain_ssl_cert",
    "arn:aws:ssm:${var.region}:${local.account_id}:parameter/cabal/control_domain_chain_cert",
  ]
  ecs_service_arns = [
    for name in var.ecs_service_names :
    "arn:aws:ecs:${var.region}:${local.account_id}:service/${var.ecs_cluster_name}/${name}"
  ]
}

resource "aws_iam_role" "certbot_lambda" {
  name = "cabal-certbot-renewal-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "route53" {
  name = "route53-dns-challenge"
  role = aws_iam_role.certbot_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:GetChange",
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = [
          "arn:aws:route53:::hostedzone/${var.zone_id}",
          "arn:aws:route53:::change/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "ssm" {
  name = "ssm-cert-parameters"
  role = aws_iam_role.certbot_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
        ]
        Resource = local.ssm_parameter_arns
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecs" {
  name = "ecs-force-deploy"
  role = aws_iam_role.certbot_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
        ]
        Resource = local.ecs_service_arns
      }
    ]
  })
}

resource "aws_iam_role_policy" "logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.certbot_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.certbot.arn}:*"
      }
    ]
  })
}
