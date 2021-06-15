resource "aws_iam_role" "cabal_stack_role" {
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
  
  inline_policy {
    name   = "cabal-stack-policy"
    policy = <<EOF
{
    "Statement": [
        {
            "Action": [
                "ec2:*",
                "iam:PassRole",
                "cloudwatch:GetMetricStatistics",
                "cloudwatch:DescribeAlarms",
                "ecs:*",
                "elasticloadbalancing:*",
                "rds:*"
            ],
            "Effect": "Allow",
            "Resource": [
                "*"
            ]
        }
    ]
}
EOF
  }
  tags   = {
    Name                 = "cabal-stack-role"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
}

resource "aws_iam_role" "cabal_instance_profile_role" {
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

resource "aws_iam_instance_profile" "cabal_stack_instance_profile" {
  name = "cabal-instance-profile"
  role = aws_iam_role.cabal_instance_profile_role.name
}

resource "aws_opsworks_stack" "cabal_stack" {
  name                         = "cabal-stack"
  region                       = var.region
  service_role_arn             = aws_iam_role.cabal_stack_role.arn
  default_instance_profile_arn = aws_iam_instance_profile.cabal_stack_instance_profile.arn

  tags                         = {
    Name                 = "cabal-stack"
    managed_by_terraform = "y"
    terraform_repo       = var.repo
  }
  custom_json                  = <<EOT
{
 "foobar": {
    "version": "1.0.0"
  }
}
EOT
}