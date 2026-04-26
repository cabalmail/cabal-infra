# ── Healthchecks ECS service (Phase 2 heartbeat monitoring) ────
#
# Self-hosted Healthchecks (Django + uWSGI). One task; SQLite state on
# EFS so it survives task replacement. Cycles in place because SQLite is
# single-writer.
#
# Bootstrap (once, via the web UI behind Cognito):
#   1. Visit https://heartbeat.<control-domain>/ — Cognito challenges.
#   2. Sign up the first account inside Healthchecks (REGISTRATION_OPEN
#      stays true on first apply, then flip to false in SSM and bounce
#      the task).
#   3. Create one check per scheduled job; copy the ping URL into the
#      corresponding /cabal/healthcheck_ping_* SSM parameter.

resource "aws_efs_access_point" "healthchecks" {
  file_system_id = var.efs_id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/healthchecks"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }
}

resource "aws_cloudwatch_log_group" "healthchecks" {
  name              = "/ecs/cabal-healthchecks"
  retention_in_days = 30
}

resource "aws_iam_role" "healthchecks_execution" {
  name = "cabal-healthchecks-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "healthchecks_execution_managed" {
  role       = aws_iam_role.healthchecks_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The execution role pulls SECRET_KEY from SSM at task start (ECS native
# `secrets` mechanism). Scoped to the one parameter.
resource "aws_iam_role_policy" "healthchecks_execution_ssm" {
  name = "cabal-healthchecks-execution-ssm"
  role = aws_iam_role.healthchecks_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameters"]
      Resource = [
        aws_ssm_parameter.healthchecks_secret_key.arn,
      ]
    }]
  })
}

resource "aws_iam_role" "healthchecks_task" {
  name = "cabal-healthchecks-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# ECS Exec — needed to bootstrap the first admin account from the
# console (`manage.py createsuperuser`) and inspect the SQLite store.
resource "aws_iam_role_policy" "healthchecks_task_exec" {
  name = "cabal-healthchecks-task-exec"
  role = aws_iam_role.healthchecks_task.id

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

resource "aws_ecs_task_definition" "healthchecks" {
  family                   = "cabal-healthchecks"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.healthchecks_execution.arn
  task_role_arn            = aws_iam_role.healthchecks_task.arn

  container_definitions = jsonencode([{
    name              = "healthchecks"
    image             = "${var.healthchecks_ecr_repository_url}:${var.image_tag}"
    essential         = true
    memoryReservation = 256
    memory            = 512

    portMappings = [
      { containerPort = 8000, protocol = "tcp" }
    ]

    environment = [
      { name = "DB", value = "sqlite" },
      { name = "DB_NAME", value = "/data/hc.sqlite" },
      { name = "ALLOWED_HOSTS", value = "heartbeat.${var.control_domain}" },
      { name = "SITE_ROOT", value = "https://heartbeat.${var.control_domain}" },
      { name = "SITE_NAME", value = "Cabalmail Healthchecks" },
      { name = "DEFAULT_FROM_EMAIL", value = "noreply@${var.control_domain}" },
      { name = "DEBUG", value = "False" },
      { name = "REGISTRATION_OPEN", value = "True" },
      { name = "USE_PAYMENTS", value = "False" },
      { name = "EMAIL_HOST", value = "" },
      { name = "SECURE_PROXY_SSL_HEADER", value = "HTTP_X_FORWARDED_PROTO,https" },
    ]

    secrets = [
      { name = "SECRET_KEY", valueFrom = aws_ssm_parameter.healthchecks_secret_key.name },
    ]

    mountPoints = [{
      sourceVolume  = "healthchecks-data"
      containerPath = "/data"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.healthchecks.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "healthchecks"
        "mode"                  = "non-blocking"
      }
    }
  }])

  volume {
    name = "healthchecks-data"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.healthchecks.id
        iam             = "DISABLED"
      }
    }
  }
}

resource "aws_lb_target_group" "healthchecks" {
  name        = "cabal-healthchecks"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

resource "aws_ecs_service" "healthchecks" {
  name            = "cabal-healthchecks"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.healthchecks.arn
  desired_count   = 1

  enable_execute_command = true

  # Single-writer SQLite; cycle in place.
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  capacity_provider_strategy {
    capacity_provider = var.ecs_cluster_capacity_provider
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.healthchecks.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.healthchecks.arn
    container_name   = "healthchecks"
    container_port   = 8000
  }
}
