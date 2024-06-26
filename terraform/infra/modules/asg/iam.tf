resource "aws_iam_policy" "node_permissions" {
  name        = "cabal-${var.type}-access"
  path        = "/"
  description = "Policies for ${var.type} machines"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = [
          "s3:GetObject",
        ]
        Effect   = "Allow"
        Resource = [
          "${var.bucket_arn}/cabal.tar.gz",
        ]
      },
      {
        Action   = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:ListSecretVersionIds",
        ]
        Effect   = "Allow"
        Resource = [
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter//cabal/*",
        ]
      },
      {
        Action   = [
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Scan",
          "dynamodb:UpdateItem",
          "dynamodb:BatchGetItem",
          "dynamodb:DescribeTable",
          "dynamodb:ListTables",
          "dynamodb:Query",
          "dynamodb:ListTagsOfResource",
        ]
        Effect   = "Allow"
        Resource = var.table_arn
      },
      {
        Action   = [
          "cognito-idp:Get*",
          "cognito-idp:List*",
          "cognito-idp:Describe*",
          "cognito-idp:Verify*",
        ]
        Effect   = "Allow"
        Resource = var.user_pool_arn
      },
      {
        Action   = [
          "route53:ChangeResourceRecordSets",
        ]
        Effect   = "Allow"
        Resource = var.private_zone_arn
      },
    ]
  })
}

resource "aws_iam_role" "node_permissions" {
  name = "cabal-${var.type}-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "attachment_1" {
  role       = aws_iam_role.node_permissions.name
  policy_arn = data.aws_iam_policy.ssm.arn
}

resource "aws_iam_role_policy_attachment" "attachment_2" {
  role       = aws_iam_role.node_permissions.name
  policy_arn = aws_iam_policy.node_permissions.arn
}

resource "aws_iam_instance_profile" "asg" {
  name = "cabal-${var.type}-profile"
  role = aws_iam_role.node_permissions.name
}