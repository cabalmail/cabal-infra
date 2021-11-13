resource "aws_iam_role" "cabal_instance_role" {
  name = "cabal-ecr-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Path": "/executionServiceEC2Role/",
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

resource "aws_iam_role_policy_attachment" "cabal_role_attachment_1" {
  role       = aws_iam_role.cabal_role.name
  policy_arn = data.aws_iam_policy.ssm_policy.arn
}

resource "aws_iam_role_policy_attachment" "cabal_role_attachment_2" {
  role       = aws_iam_role.cabal_role.name
  policy_arn = data.aws_iam_policy.ecr_policy.arn
}

resource "aws_iam_policy" "cabal_ecr_logging_policy" {
  name        = "cabal-ecr-logging-policy"
  path        = "/"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:PutObject",
        ]
        Effect   = "Allow"
        Resource = aws_s3_bucket.cabal_image_builder_log_bucket.arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "cabal_instance_profile" {
  name = "cabal_instance_profile"
  role = aws_iam_role.cabal_instance_role.name
}