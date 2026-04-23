# ── Uptime Kuma ECS service ────────────────────────────────────
#
# One task; SQLite state on EFS survives task replacement. Kuma
# does not scale horizontally (single-writer sqlite), so
# desired_count stays at 1 and the deployment config cycles in place.
#
# The mail tiers already mount the shared EFS at /home; Kuma uses an
# access point to isolate its state under /uptime-kuma so its files
# never mingle with mailstores.

resource "aws_efs_access_point" "kuma" {
  file_system_id = var.efs_id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/uptime-kuma"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }
}

resource "aws_cloudwatch_log_group" "kuma" {
  name              = "/ecs/cabal-uptime-kuma"
  retention_in_days = 30
}

resource "aws_iam_role" "kuma_execution" {
  name = "cabal-uptime-kuma-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kuma_execution_managed" {
  role       = aws_iam_role.kuma_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "kuma_task" {
  name = "cabal-uptime-kuma-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# Kuma needs no AWS API access at runtime; task role is present for ECS
# Exec and future-proofing.

resource "aws_ecs_task_definition" "kuma" {
  family                   = "cabal-uptime-kuma"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.kuma_execution.arn
  task_role_arn            = aws_iam_role.kuma_task.arn

  container_definitions = jsonencode([{
    name              = "uptime-kuma"
    image             = "${var.ecr_repository_url}:${var.image_tag}"
    essential         = true
    memoryReservation = 256
    memory            = 512

    portMappings = [
      { containerPort = 3001, protocol = "tcp" }
    ]

    environment = [
      { name = "UPTIME_KUMA_PORT", value = "3001" }
    ]

    mountPoints = [{
      sourceVolume  = "kuma-data"
      containerPath = "/app/data"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.kuma.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "uptime-kuma"
        "mode"                  = "non-blocking"
      }
    }
  }])

  volume {
    name = "kuma-data"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.kuma.id
        iam             = "DISABLED"
      }
    }
  }
}

resource "aws_lb_target_group" "kuma" {
  name        = "cabal-uptime-kuma"
  port        = 3001
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

resource "aws_ecs_service" "kuma" {
  name            = "cabal-uptime-kuma"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.kuma.arn
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
    security_groups = [aws_security_group.kuma.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.kuma.arn
    container_name   = "uptime-kuma"
    container_port   = 3001
  }
}
