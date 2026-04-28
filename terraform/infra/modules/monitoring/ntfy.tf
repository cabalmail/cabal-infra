# -- ntfy ECS service -------------------------------------------
#
# Self-hosted push-notification server. One task; auth + cache state on
# EFS so they survive task replacement. Token-auth only - Cognito would
# block the Lambda publisher and the mobile subscriber, both of which
# need to reach ntfy without an OAuth dance.
#
# Bootstrap (once, via ECS Exec, see docs/monitoring.md):
#   ntfy user add --role=admin admin
#   ntfy token add admin   # paste into /cabal/ntfy_publisher_token

resource "aws_efs_access_point" "ntfy" {
  file_system_id = var.efs_id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/ntfy"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }
}

resource "aws_cloudwatch_log_group" "ntfy" {
  name              = "/ecs/cabal-ntfy"
  retention_in_days = 30
}

resource "aws_iam_role" "ntfy_execution" {
  name = "cabal-ntfy-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ntfy_execution_managed" {
  role       = aws_iam_role.ntfy_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ntfy_task" {
  name = "cabal-ntfy-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# ECS Exec requires ssmmessages:* on the task role so the operator can
# bootstrap users/tokens from the AWS console or `aws ecs execute-command`.
resource "aws_iam_role_policy" "ntfy_task_exec" {
  name = "cabal-ntfy-task-exec"
  role = aws_iam_role.ntfy_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_ecs_task_definition" "ntfy" {
  family                   = "cabal-ntfy"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ntfy_execution.arn
  task_role_arn            = aws_iam_role.ntfy_task.arn

  container_definitions = jsonencode([{
    name              = "ntfy"
    image             = "${var.ntfy_ecr_repository_url}:${var.image_tag}"
    essential         = true
    memoryReservation = 128
    memory            = 256

    command = ["serve"]

    portMappings = [
      { containerPort = 80, protocol = "tcp" }
    ]

    environment = [
      { name = "NTFY_BASE_URL", value = "https://ntfy.${var.control_domain}" },
      { name = "NTFY_LISTEN_HTTP", value = ":80" },
      { name = "NTFY_CACHE_FILE", value = "/var/cache/ntfy/cache.db" },
      { name = "NTFY_AUTH_FILE", value = "/var/cache/ntfy/user.db" },
      { name = "NTFY_AUTH_DEFAULT_ACCESS", value = "deny-all" },
      { name = "NTFY_BEHIND_PROXY", value = "true" },
      { name = "NTFY_ATTACHMENT_CACHE_DIR", value = "/var/cache/ntfy/attachments" },
    ]

    mountPoints = [{
      sourceVolume  = "ntfy-data"
      containerPath = "/var/cache/ntfy"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ntfy.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ntfy"
        "mode"                  = "non-blocking"
      }
    }
  }])

  volume {
    name = "ntfy-data"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.ntfy.id
        iam             = "DISABLED"
      }
    }
  }
}

resource "aws_lb_target_group" "ntfy" {
  name        = "cabal-ntfy"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/v1/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

resource "aws_ecs_service" "ntfy" {
  name            = "cabal-ntfy"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.ntfy.arn
  desired_count   = 1

  enable_execute_command = true

  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  capacity_provider_strategy {
    capacity_provider = var.ecs_cluster_capacity_provider
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.ntfy.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ntfy.arn
    container_name   = "ntfy"
    container_port   = 80
  }
}
