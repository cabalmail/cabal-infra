# ── Cluster-scoped Prometheus exporters ────────────────────────
#
# Three ECS services that Prometheus scrapes. cloudwatch and blackbox
# are single-task; node-exporter runs DAEMON (one task per cluster
# instance) so each EC2's host metrics are reported independently.
#
# We deviate from the §3.2 plan, which framed node_exporter as a
# per-tier sidecar in the mail-tier task definitions. A daemon service
# yields one set of host metrics per EC2 instead of three duplicates,
# and avoids the deployment churn of changing every mail-tier task
# definition. tier-specific exporters (dovecot, postfix, opendkim) are
# deferred — the postfix_exporter / sendmail mismatch needs its own
# design pass and is more naturally addressed alongside Phase 4 log
# aggregation. See CHANGELOG.

# ── cloudwatch_exporter ───────────────────────────────────────

resource "aws_cloudwatch_log_group" "cloudwatch_exporter" {
  name              = "/ecs/cabal-cloudwatch-exporter"
  retention_in_days = 30
}

resource "aws_iam_role" "cloudwatch_exporter_execution" {
  name = "cabal-cloudwatch-exporter-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_exporter_execution_managed" {
  role       = aws_iam_role.cloudwatch_exporter_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "cloudwatch_exporter_task" {
  name = "cabal-cloudwatch-exporter-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# CloudWatch read access for the exporter to scrape metrics across the
# AWS namespaces listed in docker/cloudwatch-exporter/config.yml. Tag
# permissions are needed for the exporter's metric labelling feature.
resource "aws_iam_role_policy" "cloudwatch_exporter_task" {
  name = "cabal-cloudwatch-exporter-task-policy"
  role = aws_iam_role.cloudwatch_exporter_task.id

  #tfsec:ignore:aws-iam-no-policy-wildcards
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:ListMetrics",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "tag:GetResources",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_ecs_task_definition" "cloudwatch_exporter" {
  family                   = "cabal-cloudwatch-exporter"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.cloudwatch_exporter_execution.arn
  task_role_arn            = aws_iam_role.cloudwatch_exporter_task.arn

  container_definitions = jsonencode([{
    name              = "cloudwatch-exporter"
    image             = "${var.cloudwatch_exporter_ecr_repository_url}:${var.image_tag}"
    essential         = true
    memoryReservation = 192
    memory            = 384

    portMappings = [
      { containerPort = 9106, protocol = "tcp" }
    ]

    environment = [
      { name = "AWS_REGION", value = var.region },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.cloudwatch_exporter.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "cloudwatch-exporter"
        "mode"                  = "non-blocking"
      }
    }
  }])
}

resource "aws_ecs_service" "cloudwatch_exporter" {
  name            = "cabal-cloudwatch-exporter"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.cloudwatch_exporter.arn
  desired_count   = 1

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  capacity_provider_strategy {
    capacity_provider = var.ecs_cluster_capacity_provider
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.exporters.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.monitoring["cloudwatch-exporter"].arn
  }
}

# ── blackbox_exporter ────────────────────────────────────────

resource "aws_cloudwatch_log_group" "blackbox_exporter" {
  name              = "/ecs/cabal-blackbox-exporter"
  retention_in_days = 30
}

resource "aws_iam_role" "blackbox_exporter_execution" {
  name = "cabal-blackbox-exporter-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "blackbox_exporter_execution_managed" {
  role       = aws_iam_role.blackbox_exporter_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "blackbox_exporter_task" {
  name = "cabal-blackbox-exporter-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_ecs_task_definition" "blackbox_exporter" {
  family                   = "cabal-blackbox-exporter"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.blackbox_exporter_execution.arn
  task_role_arn            = aws_iam_role.blackbox_exporter_task.arn

  container_definitions = jsonencode([{
    name              = "blackbox-exporter"
    image             = "${var.blackbox_exporter_ecr_repository_url}:${var.image_tag}"
    essential         = true
    memoryReservation = 64
    memory            = 128

    portMappings = [
      { containerPort = 9115, protocol = "tcp" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.blackbox_exporter.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "blackbox-exporter"
        "mode"                  = "non-blocking"
      }
    }
  }])
}

resource "aws_ecs_service" "blackbox_exporter" {
  name            = "cabal-blackbox-exporter"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.blackbox_exporter.arn
  desired_count   = 1

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  capacity_provider_strategy {
    capacity_provider = var.ecs_cluster_capacity_provider
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.exporters.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.monitoring["blackbox-exporter"].arn
  }
}

# ── node_exporter (DAEMON: one per ECS container instance) ───

resource "aws_cloudwatch_log_group" "node_exporter" {
  name              = "/ecs/cabal-node-exporter"
  retention_in_days = 14
}

resource "aws_iam_role" "node_exporter_execution" {
  name = "cabal-node-exporter-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_exporter_execution_managed" {
  role       = aws_iam_role.node_exporter_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "node_exporter_task" {
  name = "cabal-node-exporter-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# Daemon-strategy task definition: bind-mounts the host's /proc and
# /sys read-only and runs node_exporter with --path.rootfs=/host so it
# reports the host's view rather than the container's.
#
# Networking is `host` — daemon-strategy tasks need direct access to
# the host's network namespace to expose meaningful network metrics
# (interfaces, conntrack, etc.). Each container instance gets exactly
# one node_exporter task, listening on the host's :9100. Prometheus
# scrapes all of them via the Cloud Map A record.
resource "aws_ecs_task_definition" "node_exporter" {
  family                   = "cabal-node-exporter"
  requires_compatibilities = ["EC2"]
  network_mode             = "host"
  execution_role_arn       = aws_iam_role.node_exporter_execution.arn
  task_role_arn            = aws_iam_role.node_exporter_task.arn

  container_definitions = jsonencode([{
    name              = "node-exporter"
    image             = "${var.node_exporter_ecr_repository_url}:${var.image_tag}"
    essential         = true
    memoryReservation = 32
    memory            = 96

    command = [
      "--path.rootfs=/host",
      "--path.procfs=/host/proc",
      "--path.sysfs=/host/sys",
      "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|var/lib/docker/.+|var/lib/ecs/.+)($|/)",
      "--web.listen-address=:9100",
    ]

    portMappings = [
      { containerPort = 9100, hostPort = 9100, protocol = "tcp" }
    ]

    mountPoints = [
      { sourceVolume = "rootfs", containerPath = "/host", readOnly = true },
      { sourceVolume = "proc", containerPath = "/host/proc", readOnly = true },
      { sourceVolume = "sys", containerPath = "/host/sys", readOnly = true },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.node_exporter.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "node-exporter"
        "mode"                  = "non-blocking"
      }
    }
  }])

  volume {
    name      = "rootfs"
    host_path = "/"
  }
  volume {
    name      = "proc"
    host_path = "/proc"
  }
  volume {
    name      = "sys"
    host_path = "/sys"
  }
}

resource "aws_ecs_service" "node_exporter" {
  name                = "cabal-node-exporter"
  cluster             = var.ecs_cluster_id
  task_definition     = aws_ecs_task_definition.node_exporter.arn
  scheduling_strategy = "DAEMON"

  # DAEMON-strategy services place exactly one task per container
  # instance the cluster's capacity provider supplies. No desired_count
  # — ECS picks the count automatically.

  # network_mode = host means no awsvpc → no security_groups block; the
  # task uses the host's SG. `service_registries` still works for host
  # network mode and registers the host's primary IP.
  service_registries {
    registry_arn = aws_service_discovery_service.monitoring["node-exporter"].arn
  }
}
