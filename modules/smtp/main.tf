data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]
  name_regex  = "^amzn2-"
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_default_tags" "current" {}

data "aws_iam_policy" "ssm_policy" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "cabal_smtp_policy" {
  name        = "cabal-smtp-${var.type}-access"
  path        = "/"
  description = "Policies for SMTP machines"

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
    ]
  })
}

resource "aws_iam_role" "cabal_smtp_role" {
  name = "cabal-smtp-${var.type}-role"

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

resource "aws_iam_role_policy_attachment" "cabal_smtp_role_attachment_1" {
  role       = aws_iam_role.cabal_smtp_role.name
  policy_arn = data.aws_iam_policy.ssm_policy.arn
}

resource "aws_iam_role_policy_attachment" "cabal_smtp_role_attachment_2" {
  role       = aws_iam_role.cabal_smtp_role.name
  policy_arn = aws_iam_policy.cabal_smtp_policy.arn
}

resource "aws_iam_instance_profile" "cabal_smtp_instance_profile" {
  name = "cabal-smtp-${var.type}-profile"
  role = aws_iam_role.cabal_smtp_role.name
}

resource "aws_security_group" "cabal_smtp_sg" {
  name        = "cabal-smtp-${var.type}-sg"
  description = "Allow SMTP inbound traffic"
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
  security_group_id = aws_security_group.cabal_smtp_sg.id
}

resource "aws_security_group_rule" "allow_smtp25" {
  type              = "ingress"
  protocol          = "tcp"
  to_port           = 25
  from_port         = 25
  description       = "Allow incoming smtp from anywhere"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.cabal_smtp_sg.id
}

resource "aws_security_group_rule" "allow_smtp465" {
  type              = "ingress"
  protocol          = "tcp"
  to_port           = 465
  from_port         = 465
  description       = "Allow incoming smtp from anywhere"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.cabal_smtp_sg.id
}

resource "aws_security_group_rule" "allow_smtp587" {
  type              = "ingress"
  protocol          = "tcp"
  to_port           = 587
  from_port         = 587
  description       = "Allow incoming smtp from anywhere"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.cabal_smtp_sg.id
}

resource "aws_launch_configuration" "cabal_smtp_cfg" {
  name_prefix           = "smtp-${var.type}-"
  image_id              = data.aws_ami.amazon_linux_2.id
  instance_type         = "t2.micro"
  security_groups       = [aws_security_group.cabal_smtp_sg.id]
  iam_instance_profile  = aws_iam_instance_profile.cabal_smtp_instance_profile.name
  lifecycle {
    create_before_destroy = true
  }
  user_data             = templatefile("${path.module}/userdata", {
    control_domain  = var.control_domain,
    artifact_bucket = var.artifact_bucket,
    efs_dns         = var.efs_dns,
    type            = var.type
  })
}

resource "aws_autoscaling_group" "cabal_smtp_asg" {
  vpc_zone_identifier   = var.private_subnets[*].id
  desired_capacity      = var.scale.des
  max_size              = var.scale.max
  min_size              = var.scale.min
  launch_configuration  = aws_launch_configuration.cabal_smtp_cfg.id
  target_group_arns     = [var.target_group_arn]
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [
      tag,
    ]
  }
  tag {
    key                 = "Name"
    value               = "smtp-asg-${var.type}-${formatdate("YYYYMMDDhhmmss", timestamp())}"
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