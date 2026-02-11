/**
* ECS cluster with EC2 capacity for the containerized mail service.
*
* A single EC2 instance runs all three tiers (IMAP, SMTP-IN, SMTP-OUT) at
* baseline. The capacity provider scales out additional instances only when
* ECS cannot place tasks on the existing ones.
*/

data "aws_caller_identity" "current" {}

# ── ECS-optimized AMI ──────────────────────────────────────────

data "aws_ami" "ecs_optimized" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-2.0.*-x86_64-ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── ECS cluster ────────────────────────────────────────────────

resource "aws_ecs_cluster" "mail" {
  name = "cabal-mail"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ── Launch template for ECS instances ──────────────────────────

resource "aws_launch_template" "ecs" {
  name_prefix   = "cabal-ecs-"
  image_id      = data.aws_ami.ecs_optimized.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.ecs_instance.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.mail.name}" >> /etc/ecs/ecs.config
  EOF
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 30
      volume_type = "gp3"
      iops        = 3000
      throughput  = 125
    }
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── ASG for ECS instances ─────────────────────────────────────

resource "aws_autoscaling_group" "ecs" {
  name_prefix         = "cabal-ecs-"
  vpc_zone_identifier = var.private_subnets[*].id
  desired_capacity    = 1
  max_size            = 3
  min_size            = 1

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "cabal-ecs-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Capacity provider ─────────────────────────────────────────

resource "aws_ecs_capacity_provider" "ec2" {
  name = "cabal-ec2"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status          = "ENABLED"
      target_capacity = 100
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "mail" {
  cluster_name       = aws_ecs_cluster.mail.name
  capacity_providers = [aws_ecs_capacity_provider.ec2.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 100
  }
}

# ── Security group for ECS container instances ─────────────────
#
# This allows ECS tasks running in awsvpc mode to reach the
# instance (for the ECS agent) and allows all outbound traffic.

resource "aws_security_group" "ecs_instance" {
  name        = "cabal-ecs-instance-sg"
  description = "ECS container instance security group"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "ecs_instance_egress" {
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-egress-sgr
  description       = "Allow all outgoing"
  security_group_id = aws_security_group.ecs_instance.id
}

resource "aws_security_group_rule" "ecs_instance_ingress_vpc" {
  type              = "ingress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = [var.cidr_block]
  description       = "Allow all traffic from VPC"
  security_group_id = aws_security_group.ecs_instance.id
}

# ── CloudWatch log groups ──────────────────────────────────────

resource "aws_cloudwatch_log_group" "tier" {
  for_each          = local.tiers
  name              = "/ecs/cabal-${each.key}"
  retention_in_days = 30
}
