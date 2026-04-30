# -- Alertmanager ECS service -----------------------------------
#
# Receives alerts from Prometheus and posts to the alert_sink Lambda
# (which fans out to Pushover / ntfy). Single task; silences and the
# notification log live on EFS so they survive task replacement.

resource "aws_efs_access_point" "alertmanager" {
  file_system_id = var.efs_id

  posix_user {
    uid = 65534
    gid = 65534
  }

  root_directory {
    path = "/alertmanager"
    creation_info {
      owner_uid   = 65534
      owner_gid   = 65534
      permissions = "0755"
    }
  }
}

resource "aws_cloudwatch_log_group" "alertmanager" {
  name              = "/ecs/cabal-alertmanager"
  retention_in_days = 30
}

resource "aws_iam_role" "alertmanager_execution" {
  name = "cabal-alertmanager-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alertmanager_execution_managed" {
  role       = aws_iam_role.alertmanager_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Execution role pulls the alert_sink shared secret from SSM at task
# start so Alertmanager can sign its webhook calls. Scoped to the one
# parameter.
resource "aws_iam_role_policy" "alertmanager_execution_ssm" {
  name = "cabal-alertmanager-execution-ssm"
  role = aws_iam_role.alertmanager_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = [aws_ssm_parameter.alert_secret.arn]
    }]
  })
}

resource "aws_iam_role" "alertmanager_task" {
  name = "cabal-alertmanager-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "alertmanager_task_exec" {
  name = "cabal-alertmanager-task-exec"
  role = aws_iam_role.alertmanager_task.id

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

resource "aws_ecs_task_definition" "alertmanager" {
  family                   = "cabal-alertmanager"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.alertmanager_execution.arn
  task_role_arn            = aws_iam_role.alertmanager_task.arn

  container_definitions = jsonencode([{
    name              = "alertmanager"
    image             = local.service_image["alertmanager"]
    essential         = true
    memoryReservation = 128
    memory            = 256

    portMappings = [
      { containerPort = 9093, protocol = "tcp" }
    ]

    environment = [
      { name = "ALERT_SINK_URL", value = aws_lambda_function_url.alert_sink.function_url },
      { name = "ALERTMANAGER_EXTERNAL_URL", value = "http://alertmanager.cabal-monitoring.cabal.internal:9093" },
    ]

    secrets = [
      { name = "ALERT_SECRET", valueFrom = aws_ssm_parameter.alert_secret.name },
    ]

    mountPoints = [{
      sourceVolume  = "alertmanager-data"
      containerPath = "/alertmanager"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.alertmanager.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "alertmanager"
        "mode"                  = "non-blocking"
      }
    }
  }])

  volume {
    name = "alertmanager-data"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.alertmanager.id
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

resource "aws_ecs_service" "alertmanager" {
  name            = "cabal-alertmanager"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.alertmanager.arn
  desired_count   = var.quiesced ? 0 : 1

  enable_execute_command = true

  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  capacity_provider_strategy {
    capacity_provider = var.ecs_cluster_capacity_provider
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.alertmanager.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.monitoring["alertmanager"].arn
  }

  # See aws_ecs_service.imap in modules/ecs/services.tf for rationale.
  lifecycle {
    ignore_changes = [task_definition]
  }
}
