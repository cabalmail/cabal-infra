resource "aws_iam_policy" "cabal_policy" {
  name        = "cabal-${var.type}-access"
  path        = "/"
  description = "Policies for ${var.type} machines"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = [
          "s3:*",
        ]
        Effect   = "Allow"
        Resource = [
          var.s3_arn,
          "${var.s3_arn}/*",
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
          "arn:aws:secretsmanager:us-east-1:715401949493:secret:/cabal/*",
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
    ]
  })
}

resource "aws_iam_role" "cabal_role" {
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

resource "aws_iam_role_policy_attachment" "cabal_role_attachment_1" {
  role       = aws_iam_role.cabal_role.name
  policy_arn = data.aws_iam_policy.ssm_policy.arn
}

resource "aws_iam_role_policy_attachment" "cabal_role_attachment_2" {
  role       = aws_iam_role.cabal_role.name
  policy_arn = aws_iam_policy.cabal_policy.arn
}

resource "aws_iam_instance_profile" "cabal_instance_profile" {
  name = "cabal-${var.type}-profile"
  role = aws_iam_role.cabal_role.name
}

resource "aws_security_group" "cabal_sg" {
  name        = "cabal-${var.type}-sg"
  description = "Allow ${var.type} inbound traffic"
  vpc_id      = var.vpc.id
}

resource "aws_security_group_rule" "allow_all" {
  type              = "egress"
  protocol          = "-1"
  to_port           = 0
  from_port         = 0
  description       = "Allow all outgoing"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.cabal_sg.id
}

resource "aws_security_group_rule" "allow" {
  count             = length(var.ports)
  type              = "ingress"
  protocol          = "tcp"
  to_port           = var.ports[count.index]
  from_port         = var.ports[count.index]
  description       = "Allow incoming port ${var.ports[count.index]} ${var.type} from anywhere"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.cabal_sg.id
}

resource "aws_launch_configuration" "cabal_cfg" {
  name_prefix           = "${var.type}-"
  image_id              = data.aws_ami.amazon_linux_2.id
  instance_type         = "t2.micro"
  security_groups       = [aws_security_group.cabal_sg.id]
  iam_instance_profile  = aws_iam_instance_profile.cabal_instance_profile.name
  lifecycle {
    create_before_destroy = true
  }
  user_data             = templatefile("${path.module}/${var.type}_userdata", {
    control_domain  = var.control_domain,
    artifact_bucket = var.artifact_bucket,
    efs_dns         = var.efs_dns,
    region          = var.region,
    client_id       = var.client_id,
    pool_id         = var.user_pool_id,
    chef_license    = var.chef_license,
    type            = var.type
  })
}

# TODO
# - auth sufficient pam_exec.so expose_authtok /usr/bin/cognito.bash

resource "aws_autoscaling_group" "cabal_asg" {
  vpc_zone_identifier   = var.private_subnets[*].id
  desired_capacity      = var.scale.des
  max_size              = var.scale.max
  min_size              = var.scale.min
  launch_configuration  = aws_launch_configuration.cabal_cfg.id
  target_group_arns     = [var.target_group_arn]
  lifecycle {
    create_before_destroy = true
  }
  tag {
    key                 = "Name"
    value               = "asg-${var.type}-${data.aws_ami.amazon_linux_2.id}"
    propagate_at_launch = true
  }
  dynamic "tag" {
    for_each = data.aws_default_tags.current.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}