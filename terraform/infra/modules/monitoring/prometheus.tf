# -- Prometheus ECS service -------------------------------------
#
# Single task; TSDB on EFS so retained metrics survive task replacement.
# Like Kuma and Healthchecks, Prometheus is single-writer at this size,
# so desired_count stays at 1 and the deployment cycles in place.
#
# Not exposed publicly - Grafana proxies queries through the data source
# proxy and Alertmanager pulls alerts via the in-cluster DNS name.
# Operators reach the Prometheus UI through `aws ecs execute-command`
# port-forwarding when needed.

resource "aws_efs_access_point" "prometheus" {
  file_system_id = var.efs_id

  posix_user {
    # Upstream image runs as `nobody` (uid 65534).
    uid = 65534
    gid = 65534
  }

  root_directory {
    path = "/prometheus"
    creation_info {
      owner_uid   = 65534
      owner_gid   = 65534
      permissions = "0755"
    }
  }
}

resource "aws_cloudwatch_log_group" "prometheus" {
  name              = "/ecs/cabal-prometheus"
  retention_in_days = 30
}

resource "aws_iam_role" "prometheus_execution" {
  name = "cabal-prometheus-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "prometheus_execution_managed" {
  role       = aws_iam_role.prometheus_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "prometheus_task" {
  name = "cabal-prometheus-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "prometheus_task_exec" {
  name = "cabal-prometheus-task-exec"
  role = aws_iam_role.prometheus_task.id

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

resource "aws_ecs_task_definition" "prometheus" {
  family                   = "cabal-prometheus"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.prometheus_execution.arn
  task_role_arn            = aws_iam_role.prometheus_task.arn

  container_definitions = jsonencode([{
    name              = "prometheus"
    image             = "${var.prometheus_ecr_repository_url}:${var.image_tag}"
    essential         = true
    memoryReservation = 384
    memory            = 768

    portMappings = [
      { containerPort = 9090, protocol = "tcp" }
    ]

    environment = [
      { name = "CONTROL_DOMAIN", value = var.control_domain },
      { name = "ENVIRONMENT", value = var.environment },
    ]

    mountPoints = [{
      sourceVolume  = "prometheus-data"
      containerPath = "/prometheus"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.prometheus.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "prometheus"
        "mode"                  = "non-blocking"
      }
    }
  }])

  volume {
    name = "prometheus-data"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.prometheus.id
        iam             = "DISABLED"
      }
    }
  }

  # See docs/0.9.0/build-deploy-simplification-plan.md. App deploys mutate
  # the image tag out-of-band via aws ecs register-task-definition; Terraform
  # must not roll those forward updates back on a topology-only apply.
  lifecycle {
    ignore_changes = [container_definitions]
  }
}

resource "aws_ecs_service" "prometheus" {
  name            = "cabal-prometheus"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = var.quiesced ? 0 : 1

  enable_execute_command = true

  # Single-writer TSDB; cycle in place.
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  capacity_provider_strategy {
    capacity_provider = var.ecs_cluster_capacity_provider
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.prometheus.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.monitoring["prometheus"].arn
  }
}
