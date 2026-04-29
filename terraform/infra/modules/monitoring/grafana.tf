# -- Grafana ECS service ----------------------------------------
#
# Public dashboards UI behind the same Cognito challenge as Kuma /
# Healthchecks. Single task; SQLite store on EFS so user-edited
# dashboards and saved queries survive task replacement.
#
# Provisioned config (datasource + four Phase 3 dashboards) is baked
# into the image. UI edits override provisioning per-instance.

resource "aws_efs_access_point" "grafana" {
  file_system_id = var.efs_id

  posix_user {
    # Upstream image's `grafana` user is uid/gid 472.
    uid = 472
    gid = 472
  }

  root_directory {
    path = "/grafana"
    creation_info {
      owner_uid   = 472
      owner_gid   = 472
      permissions = "0755"
    }
  }
}

resource "aws_cloudwatch_log_group" "grafana" {
  name              = "/ecs/cabal-grafana"
  retention_in_days = 30
}

resource "aws_iam_role" "grafana_execution" {
  name = "cabal-grafana-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_execution_managed" {
  role       = aws_iam_role.grafana_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "grafana_execution_ssm" {
  name = "cabal-grafana-execution-ssm"
  role = aws_iam_role.grafana_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = [aws_ssm_parameter.grafana_admin_password.arn]
    }]
  })
}

resource "aws_iam_role" "grafana_task" {
  name = "cabal-grafana-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "grafana_task_exec" {
  name = "cabal-grafana-task-exec"
  role = aws_iam_role.grafana_task.id

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

resource "aws_ecs_task_definition" "grafana" {
  family                   = "cabal-grafana"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.grafana_execution.arn
  task_role_arn            = aws_iam_role.grafana_task.arn

  container_definitions = jsonencode([{
    name              = "grafana"
    image             = "${var.grafana_ecr_repository_url}:${var.image_tag}"
    essential         = true
    memoryReservation = 256
    memory            = 512

    portMappings = [
      { containerPort = 3000, protocol = "tcp" }
    ]

    environment = [
      # Cognito sits at the ALB layer and authenticates every request
      # before it reaches Grafana, so Grafana's own anonymous-access
      # mode is enabled - the Cognito email is propagated as the
      # X-WEBAUTH-USER header for visibility, but admin operations
      # still require the local admin password.
      { name = "GF_SERVER_ROOT_URL", value = "https://metrics.${var.control_domain}" },
      { name = "GF_AUTH_ANONYMOUS_ENABLED", value = "true" },
      { name = "GF_AUTH_ANONYMOUS_ORG_ROLE", value = "Viewer" },
      { name = "GF_AUTH_DISABLE_LOGIN_FORM", value = "false" },
      { name = "GF_USERS_DEFAULT_THEME", value = "dark" },
      # Data dir is mounted at /grafana-data, NOT /var/lib/grafana.
      # The upstream image creates /var/lib/grafana with explicit
      # ownership; bind-mounting EFS onto that path makes dockerd's
      # copy-up try to chown the host volume mount, which the access
      # point rejects (`operation not permitted`) - same family as
      # the Kuma and Healthchecks chown gotchas. Mounting at a path
      # that doesn't exist in the image skips copy-up entirely.
      # Provisioning files live under /etc/grafana/provisioning,
      # baked into the image at a path the EFS mount doesn't shadow.
      { name = "GF_PATHS_DATA", value = "/grafana-data" },
      { name = "GF_PATHS_PROVISIONING", value = "/etc/grafana/provisioning" },
      { name = "GF_INSTALL_PLUGINS", value = "" },
    ]

    secrets = [
      { name = "GF_SECURITY_ADMIN_PASSWORD", valueFrom = aws_ssm_parameter.grafana_admin_password.name },
    ]

    mountPoints = [{
      sourceVolume  = "grafana-data"
      containerPath = "/grafana-data"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.grafana.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "grafana"
        "mode"                  = "non-blocking"
      }
    }
  }])

  volume {
    name = "grafana-data"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.grafana.id
        iam             = "DISABLED"
      }
    }
  }
}

resource "aws_lb_target_group" "grafana" {
  name        = "cabal-grafana"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/api/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

resource "aws_ecs_service" "grafana" {
  name            = "cabal-grafana"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = var.quiesced ? 0 : 1

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
    security_groups = [aws_security_group.grafana.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = 3000
  }

  service_registries {
    registry_arn = aws_service_discovery_service.monitoring["grafana"].arn
  }
}
