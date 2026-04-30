# -- Healthchecks ECS service (Phase 2 heartbeat monitoring) ----
#
# Self-hosted Healthchecks (Django + uWSGI). One task; SQLite state on
# EFS so it survives task replacement. Cycles in place because SQLite is
# single-writer.
#
# Bootstrap (once, via the web UI behind Cognito):
#   1. Visit https://heartbeat.<control-domain>/ - Cognito challenges.
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

# ECS Exec - needed to bootstrap the first admin account from the
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

    # Force the container to run as the same uid/gid the EFS access
    # point translates I/O to. The upstream image creates a `hc` system
    # user (uid ~999) and runs as it; without this override, every
    # write to the mounted data dir fails with EACCES because EFS
    # exposes files as 1000:1000.
    user = "1000:1000"

    portMappings = [
      { containerPort = 8000, protocol = "tcp" }
    ]

    environment = [
      { name = "DB", value = "sqlite" },
      # Mount target deliberately not /data: the upstream image runs
      # `mkdir /data && chown hc /data`, so dockerd's copy-up tries to
      # chown the host EFS mount path to hc's uid (~999) at container
      # creation time. EFS access points reject the chown regardless of
      # caller, and the task fails with CannotCreateContainerError.
      # /var/local/healthchecks-data does not exist in the image, so no
      # copy-up runs.
      { name = "DB_NAME", value = "/var/local/healthchecks-data/hc.sqlite" },
      # ALLOWED_HOSTS is `*` because the ALB target-group health check
      # cannot set a custom Host header - it sends `Host: <target-ip>`,
      # which fails Django's host validation and 400s the probe. The
      # ECS task sits in a private subnet behind a security group that
      # only accepts the ALB SG, and the ALB listener rule for
      # `heartbeat.<control-domain>` is the only public ingress to this
      # target group, so hostname enforcement is already done at the
      # ALB layer; Django doesn't need to repeat it.
      { name = "ALLOWED_HOSTS", value = "*" },
      { name = "SITE_ROOT", value = "https://heartbeat.${var.control_domain}" },
      { name = "SITE_NAME", value = "Cabalmail Healthchecks" },
      { name = "SITE_LOGO_URL", value = "https://admin.cabalmail.net/logo192.png" },
      # From: domain piggy-backs on the `mail-admin.<first-mail-domain>`
      # subdomain that the DMARC ingestion infrastructure already
      # provisions (see terraform/infra/modules/app/dmarc_user.tf):
      # MX, SPF, DKIM and DMARC records all land there as part of the
      # standard apply. Cabalmail does not allow addressing on the
      # apex of a mail domain by design, so neither <control-domain>
      # nor mail_domains[0] itself resolves to MX/A - both fail
      # sendmail's check_mail with `Domain of sender ... does not
      # exist`. mail-admin.<first-mail-domain> has full DNS, so it's
      # the natural place for system-originated mail like the
      # Healthchecks magic-link FROM. Local part is free to vary.
      { name = "DEFAULT_FROM_EMAIL", value = "noreply@mail-admin.${var.mail_domains[0]}" },
      { name = "DEBUG", value = "False" },
      # Django expects the Title-Cased form ("True"/"False"), not the
      # Terraform/JSON lower-case form (true/false), so we render the
      # bool by hand rather than tostring(...).
      { name = "REGISTRATION_OPEN", value = var.healthchecks_registration_open ? "True" : "False" },
      { name = "USE_PAYMENTS", value = "False" },
      # SMTP wired to the IMAP tier's local-delivery sendmail via Cloud
      # Map service discovery. We're not relaying outbound - every
      # address Healthchecks emails is itself a Cabalmail-hosted
      # address, so we deliver inbound to ourselves. That's why no
      # auth, no DKIM, no Cognito service user is needed: inbound MX
      # accepts mail for hosted domains from any source, and IMAP's
      # /etc/mail/access has explicit OK entries for every configured
      # address (see docker/shared/generate-config.sh:gen_imap_access).
      # Plain port 25 (no STARTTLS) because the wildcard cert is for
      # `*.${var.control_domain}`, not `*.cabal.internal`, and the hop
      # is task-to-task in private subnets - no public network in
      # between. Limitation: Healthchecks can only email Cabalmail
      # addresses; magic links to e.g. gmail won't deliver. Acceptable
      # for a single-operator setup.
      { name = "EMAIL_HOST", value = "imap.cabal.internal" },
      { name = "EMAIL_PORT", value = "25" },
      { name = "EMAIL_USE_TLS", value = "False" },
      { name = "EMAIL_USE_SSL", value = "False" },
      { name = "SECURE_PROXY_SSL_HEADER", value = "HTTP_X_FORWARDED_PROTO,https" },
    ]

    secrets = [
      { name = "SECRET_KEY", valueFrom = aws_ssm_parameter.healthchecks_secret_key.name },
    ]

    mountPoints = [{
      sourceVolume  = "healthchecks-data"
      containerPath = "/var/local/healthchecks-data"
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

  # See docs/0.9.0/build-deploy-simplification-plan.md. App deploys mutate
  # the image tag out-of-band via aws ecs register-task-definition; Terraform
  # must not roll those forward updates back on a topology-only apply.
  lifecycle {
    ignore_changes = [container_definitions]
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
    security_groups = [aws_security_group.healthchecks.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.healthchecks.arn
    container_name   = "healthchecks"
    container_port   = 8000
  }

  # Phase 4 section 3 - registers the task in cabal-monitoring.cabal.internal
  # so the healthchecks_iac Lambda can reach the API directly without
  # going through the Cognito-fronted public ALB. The API key on the
  # Lambda is sufficient auth.
  service_registries {
    registry_arn = aws_service_discovery_service.monitoring["healthchecks"].arn
  }

  # See aws_ecs_service.imap in modules/ecs/services.tf for rationale.
  lifecycle {
    ignore_changes = [task_definition]
  }
}
