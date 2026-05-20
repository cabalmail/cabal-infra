/**
* ECS task definitions for the three mail tiers.
*
* Each task runs a single container in awsvpc network mode on EC2 launch type.
* Environment variables and secrets from SSM Parameter Store are injected by
* the ECS agent at task start.
*/

# Phase 2 heartbeat: when var.healthcheck_ping_param is set, ECS injects
# HEALTHCHECK_PING_URL into each tier from SSM. reconfigure.sh reads it
# at runtime and pings Healthchecks at the end of each loop iteration.
locals {
  healthcheck_secrets = var.healthcheck_ping_param != "" ? [
    { name = "HEALTHCHECK_PING_URL", valueFrom = var.healthcheck_ping_param },
  ] : []
}

# -- IMAP task definition --------------------------------------

resource "aws_ecs_task_definition" "imap" {
  family                   = "cabal-imap"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "imap"
    image     = local.tier_image["imap"]
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

    secrets = concat([
      { name = "MASTER_PASSWORD", valueFrom = "/cabal/master_password" },
      { name = "TLS_CA_BUNDLE", valueFrom = "/cabal/control_domain_chain_cert" },
      { name = "TLS_CERT", valueFrom = "/cabal/control_domain_ssl_cert" },
      { name = "TLS_KEY", valueFrom = "/cabal/control_domain_ssl_key" },
    ], local.healthcheck_secrets)

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
        "mode"                  = "non-blocking"
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

  # See docs/0.9.0/build-deploy-simplification-plan.md. App deploys mutate
  # the image tag out-of-band via aws ecs register-task-definition; Terraform
  # must not roll those forward updates back on a topology-only apply.
  lifecycle {
    ignore_changes = [container_definitions]
  }
}

# -- SMTP-IN task definition -----------------------------------

resource "aws_ecs_task_definition" "smtp_in" {
  family                   = "cabal-smtp-in"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "smtp-in"
    image     = local.tier_image["smtp-in"]
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

    secrets = concat([
      { name = "TLS_CA_BUNDLE", valueFrom = "/cabal/control_domain_chain_cert" },
      { name = "TLS_CERT", valueFrom = "/cabal/control_domain_ssl_cert" },
      { name = "TLS_KEY", valueFrom = "/cabal/control_domain_ssl_key" },
    ], local.healthcheck_secrets)

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
        "mode"                  = "non-blocking"
      }
    }
  }])

  lifecycle {
    ignore_changes = [container_definitions]
  }
}

# -- SMTP-OUT task definition ----------------------------------

# Marker resource for one-shot replacement of the smtp-out task
# definition. The lifecycle ignore_changes clause below would otherwise
# silently swallow any update to fields inside container_definitions
# (mountPoints, stopTimeout) - it protects out-of-band image-tag
# rotations from being clobbered, but as a side effect also blocks
# legitimate topology changes inside the container block. Bumping this
# input forces a destroy+recreate, which runs a fresh create (not
# governed by ignore_changes) and so picks up the full container_definitions
# from config. Subsequent applies revert to the steady-state ignore.
#
# See docs/0.9.x/smtp-out-queue-persistence-plan.md.
resource "terraform_data" "smtp_out_taskdef_revision_marker" {
  input = "smtp-queue-mount-v1"
}

resource "aws_ecs_task_definition" "smtp_out" {
  family                   = "cabal-smtp-out"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "smtp-out"
    image     = local.tier_image["smtp-out"]
    essential = true

    memoryReservation = 448
    memory            = 640

    # Give sendmail up to ~110s to finish an in-flight delivery before
    # SIGKILL. Combined with supervisord stopwaitsecs=110 in the smtp-out
    # image, this turns the persistent EFS-backed queue into the safety
    # net rather than the primary mechanism for surviving deploys. ECS
    # hard-caps stopTimeout at 120 for EC2 launch type.
    stopTimeout = 120

    portMappings = [
      { containerPort = 465, protocol = "tcp" },
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

    secrets = concat([
      { name = "TLS_CA_BUNDLE", valueFrom = "/cabal/control_domain_chain_cert" },
      { name = "TLS_CERT", valueFrom = "/cabal/control_domain_ssl_cert" },
      { name = "TLS_KEY", valueFrom = "/cabal/control_domain_ssl_key" },
      { name = "DKIM_PRIVATE_KEY", valueFrom = "/cabal/dkim_private_key" },
    ], local.healthcheck_secrets)

    mountPoints = [{
      sourceVolume  = "smtp-queue"
      containerPath = "/var/spool/mqueue"
    }]

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
        "mode"                  = "non-blocking"
      }
    }
  }])

  # Shared sendmail MTA queue on EFS - lets a replaced smtp-out task
  # hand off its in-flight retries to whichever sibling task next scans
  # the queue. Access point pins us to /smtp-queue on the mailstore
  # filesystem with root:mail (gid=12) mode 0700 (matches AL2023 sendmail
  # rpm default). IAM auth is left disabled here for parity with the
  # IMAP mount; tightening to per-tier SG + IAM auth is a separate posture
  # decision (see plan: Non-goals).
  volume {
    name = "smtp-queue"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.smtp_queue_access_point_id
        iam             = "DISABLED"
      }
    }
  }

  lifecycle {
    ignore_changes       = [container_definitions]
    replace_triggered_by = [terraform_data.smtp_out_taskdef_revision_marker]
  }
}
