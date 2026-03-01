/**
* ECS task definitions for the three mail tiers.
*
* Each task runs a single container in awsvpc network mode on EC2 launch type.
* Environment variables replace Chef node.json attributes. Secrets are injected
* from SSM Parameter Store by the ECS agent at task start.
*/

# ── IMAP task definition ──────────────────────────────────────

resource "aws_ecs_task_definition" "imap" {
  family                   = "cabal-imap"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "imap"
    image     = "${var.ecr_repository_urls["imap"]}:${var.image_tag}"
    essential = true

    memoryReservation = 384
    memory            = 512

    portMappings = [
      { containerPort = 143, protocol = "tcp" },
      { containerPort = 993, protocol = "tcp" },
      { containerPort = 25, protocol = "tcp" },
    ]

    environment = [
      { name = "TIER", value = "imap" },
      { name = "CERT_DOMAIN", value = var.control_domain },
      { name = "AWS_REGION", value = var.region },
      { name = "COGNITO_CLIENT_ID", value = var.client_id },
      { name = "COGNITO_POOL_ID", value = var.user_pool_id },
      { name = "NETWORK_CIDR", value = var.cidr_block },
      { name = "SQS_QUEUE_URL", value = aws_sqs_queue.tier["imap"].url },
    ]

    secrets = [
      { name = "MASTER_PASSWORD", valueFrom = "/cabal/master_password" },
      { name = "TLS_CA_BUNDLE", valueFrom = "/cabal/control_domain_chain_cert" },
      { name = "TLS_CERT", valueFrom = "/cabal/control_domain_ssl_cert" },
      { name = "TLS_KEY", valueFrom = "/cabal/control_domain_ssl_key" },
    ]

    mountPoints = [{
      sourceVolume  = "mailstore"
      containerPath = "/home"
    }]

    linuxParameters = {
      capabilities = {
        add = ["NET_ADMIN"]
      }
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.tier["imap"].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "imap"
      }
    }
  }])

  volume {
    name = "mailstore"
    efs_volume_configuration {
      file_system_id = var.efs_id
      root_directory = "/"
    }
  }
}

# ── SMTP-IN task definition ───────────────────────────────────

resource "aws_ecs_task_definition" "smtp_in" {
  family                   = "cabal-smtp-in"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "smtp-in"
    image     = "${var.ecr_repository_urls["smtp-in"]}:${var.image_tag}"
    essential = true

    memoryReservation = 384
    memory            = 512

    portMappings = [
      { containerPort = 25, protocol = "tcp" },
    ]

    environment = [
      { name = "TIER", value = "smtp-in" },
      { name = "CERT_DOMAIN", value = var.control_domain },
      { name = "AWS_REGION", value = var.region },
      { name = "COGNITO_CLIENT_ID", value = var.client_id },
      { name = "COGNITO_POOL_ID", value = var.user_pool_id },
      { name = "NETWORK_CIDR", value = var.cidr_block },
      { name = "SQS_QUEUE_URL", value = aws_sqs_queue.tier["smtp-in"].url },
      { name = "IMAP_INTERNAL_HOST", value = "${aws_service_discovery_service.imap.name}.${aws_service_discovery_private_dns_namespace.mail.name}" },
    ]

    secrets = [
      { name = "TLS_CA_BUNDLE", valueFrom = "/cabal/control_domain_chain_cert" },
      { name = "TLS_CERT", valueFrom = "/cabal/control_domain_ssl_cert" },
      { name = "TLS_KEY", valueFrom = "/cabal/control_domain_ssl_key" },
    ]

    linuxParameters = {
      capabilities = {
        add = ["NET_ADMIN"]
      }
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.tier["smtp-in"].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "smtp-in"
      }
    }
  }])
}

# ── SMTP-OUT task definition ──────────────────────────────────

resource "aws_ecs_task_definition" "smtp_out" {
  family                   = "cabal-smtp-out"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "smtp-out"
    image     = "${var.ecr_repository_urls["smtp-out"]}:${var.image_tag}"
    essential = true

    memoryReservation = 448
    memory            = 640

    portMappings = [
      { containerPort = 25, protocol = "tcp" },
      { containerPort = 587, protocol = "tcp" },
    ]

    environment = [
      { name = "TIER", value = "smtp-out" },
      { name = "CERT_DOMAIN", value = var.control_domain },
      { name = "AWS_REGION", value = var.region },
      { name = "COGNITO_CLIENT_ID", value = var.client_id },
      { name = "COGNITO_POOL_ID", value = var.user_pool_id },
      { name = "NETWORK_CIDR", value = var.cidr_block },
      { name = "SQS_QUEUE_URL", value = aws_sqs_queue.tier["smtp-out"].url },
      { name = "IMAP_INTERNAL_HOST", value = "${aws_service_discovery_service.imap.name}.${aws_service_discovery_private_dns_namespace.mail.name}" },
    ]

    secrets = [
      { name = "TLS_CA_BUNDLE", valueFrom = "/cabal/control_domain_chain_cert" },
      { name = "TLS_CERT", valueFrom = "/cabal/control_domain_ssl_cert" },
      { name = "TLS_KEY", valueFrom = "/cabal/control_domain_ssl_key" },
      { name = "DKIM_PRIVATE_KEY", valueFrom = "/cabal/dkim_private_key" },
    ]

    linuxParameters = {
      capabilities = {
        add = ["NET_ADMIN"]
      }
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.tier["smtp-out"].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "smtp-out"
      }
    }
  }])
}
