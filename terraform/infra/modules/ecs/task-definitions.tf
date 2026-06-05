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

# Forces a one-time imap task-def replacement whenever this string
# changes. The imap container_definitions are otherwise frozen by
# lifecycle.ignore_changes (so out-of-band image deploys via
# deploy-ecs-service.sh are not rolled back); the side effect is that
# topology edits to the container block never reach a new revision on
# their own. Bumping the version token here forces a destroy+recreate,
# whose fresh create is not governed by ignore_changes and so picks up
# the full container_definitions from config (image included, re-pinned
# to reality by refresh-ssm-from-running.sh at plan time). See the
# smtp_out marker for the original use of this pattern.
#   v1: NET_ADMIN capability drop. The replacement also reconciles the
#       container to its current full config - notably the memory = 1024
#       cap that has been in config since the vsz_limit bump but never
#       deployed under ignore_changes.
#       (docs/0.10.x/container-runtime-hardening-plan.md phase 1)
#   v2: runtime posture - cap drop=ALL + analyzed add set, no-new-privileges,
#       initProcessEnabled (same plan, phase 2)
#   v3: re-register from current config to drop a dangling HEALTHCHECK_PING_URL
#       secret left baked in from when monitoring was enabled. Turning monitoring
#       off deleted the SSM param /cabal/healthcheck_ping_ecs_reconfigure, but
#       ignore_changes kept the now-broken secret reference on the running
#       task def, so the first image roll after that (which clones the live
#       task def) produced a revision the ECS agent could not start - it failed
#       fetching the missing parameter.
#
# The +hc suffix keys this marker on whether the healthcheck secret is present
# (var.healthcheck_ping_param != "", i.e. var.monitoring in the parent stack),
# the same condition that gates local.healthcheck_secrets below. This mirrors
# the smtp_out +sinkhole hook: flipping monitoring in either direction now
# forces a task-def replacement that adds or drops the HEALTHCHECK_PING_URL
# secret in step with the SSM param that backs it, so the secret set can never
# again drift from the parameters that exist.
resource "terraform_data" "imap_taskdef_revision_marker" {
  input = var.healthcheck_ping_param != "" ? "imap-taskdef-v3+hc" : "imap-taskdef-v3"
}

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

    # Aligned with the Dovecot service-level vsz_limit in
    # docker/imap/configs/dovecot/20-imap.conf. The hard cap accommodates
    # one full-size imap worker (1G vsz) plus the supporting processes
    # (sendmail, procmail, supervisord) and a second concurrent
    # imap worker peaking. Soft reservation leaves the scheduler room to
    # pack other containers on the same m6g.medium when the imap tier is
    # idle.
    memoryReservation = 768
    memory            = 1024

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

    # Runtime posture, phase 2 of
    # docs/0.10.x/container-runtime-hardening-plan.md. Drop every Linux
    # capability, then add back only what this tier's root-owned process
    # tree actually needs. This is the analyzed working set; the mandated
    # dev soak should TIGHTEN it - remove any cap that proves unnecessary
    # under load before promoting to stage/prod.
    #   NET_BIND_SERVICE  dovecot binds 143/993, sendmail binds 25 (all <1024)
    #   SETUID, SETGID    dovecot forks imap workers as the logged-in user;
    #                     sendmail runs delivery agents as mail/smmsp; procmail
    #                     delivers as the recipient
    #   CHOWN             sync-users.sh `install -o/-g` + useradd home dirs on
    #                     the EFS mailstore
    #   DAC_OVERRIDE      useradd/groupadd write /etc/shadow + /etc/gshadow (0000)
    #   FOWNER            useradd/install metadata ops on files they do not own
    #   KILL              the root dovecot/sendmail masters signal their
    #                     privilege-dropped (non-root) children
    #   SYS_CHROOT        dovecot imap-login chroots by default
    # initProcessEnabled runs a real init as PID 1 (reaps the supervisord
    # tree's zombies). no-new-privileges blocks setuid-binary escalation.
    linuxParameters = {
      initProcessEnabled = true
      capabilities = {
        drop = ["ALL"]
        add = [
          "CHOWN",
          "DAC_OVERRIDE",
          "FOWNER",
          "KILL",
          "NET_BIND_SERVICE",
          "SETGID",
          "SETUID",
          "SYS_CHROOT",
        ]
      }
    }

    # ECS wants the bare token; the plan's "no-new-privileges:true" is the
    # docker-CLI spelling and register-task-definition rejects it.
    dockerSecurityOptions = ["no-new-privileges"]

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

  # See docs/0.9.x/build-deploy-simplification-plan.md. App deploys mutate
  # the image tag out-of-band via aws ecs register-task-definition; Terraform
  # must not roll those forward updates back on a topology-only apply. The
  # replace_triggered_by marker is how deliberate container_definitions
  # changes (which ignore_changes would otherwise swallow) get deployed.
  lifecycle {
    ignore_changes       = [container_definitions]
    replace_triggered_by = [terraform_data.imap_taskdef_revision_marker]
  }
}

# -- SMTP-IN task definition -----------------------------------

# See imap_taskdef_revision_marker for the full rationale. Bump the
# version token to force a one-time smtp-in task-def replacement when
# its container block changes and must be deployed.
#   v1: NET_ADMIN capability drop
#       (docs/0.10.x/container-runtime-hardening-plan.md phase 1)
#   v2: runtime posture (cap drop=ALL + adds, no-new-privileges, init) - phase 2
#   v3: re-register from current config to drop the dangling HEALTHCHECK_PING_URL
#       secret stranded by the monitoring removal (see the imap marker for the
#       full story). The +hc suffix keys the marker on the healthcheck secret's
#       presence so a future monitoring flip can't strand it again.
resource "terraform_data" "smtp_in_taskdef_revision_marker" {
  input = var.healthcheck_ping_param != "" ? "smtp-in-taskdef-v3+hc" : "smtp-in-taskdef-v3"
}

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

    # Runtime posture, phase 2 (see the imap task def for the full
    # rationale). smtp-in runs only sendmail - no dovecot - so it needs
    # the same set minus SYS_CHROOT. Dev soak should TIGHTEN this.
    #   NET_BIND_SERVICE           sendmail binds 25
    #   SETUID, SETGID             delivery/queue agents run as mail/smmsp
    #   CHOWN, DAC_OVERRIDE, FOWNER  sync-users.sh user provisioning
    #   KILL                       root sendmail master signals non-root children
    linuxParameters = {
      initProcessEnabled = true
      capabilities = {
        drop = ["ALL"]
        add = [
          "CHOWN",
          "DAC_OVERRIDE",
          "FOWNER",
          "KILL",
          "NET_BIND_SERVICE",
          "SETGID",
          "SETUID",
        ]
      }
    }

    dockerSecurityOptions = ["no-new-privileges"]

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
    ignore_changes       = [container_definitions]
    replace_triggered_by = [terraform_data.smtp_in_taskdef_revision_marker]
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
# var.sinkhole is included in the input so that flipping the flag
# in either direction forces a task-def replacement, which picks up
# (or drops) the SINKHOLE_ENABLED env var. Without this hook the
# lifecycle clause would keep the running task on its existing env
# var list forever; phase 5 of docs/0.9.x/sinkhole-test-harness-plan.md.
#
# See also docs/0.9.x/smtp-out-queue-persistence-plan.md for the
# original use of this marker.
resource "terraform_data" "smtp_out_taskdef_revision_marker" {
  # Bump the version token for any change that must deploy (see the
  # mechanism described above):
  #   v1: EFS queue mount + stop-grace
  #       (docs/0.9.x/smtp-out-queue-persistence-plan.md)
  #   v2: NET_ADMIN capability drop
  #       (docs/0.10.x/container-runtime-hardening-plan.md phase 1)
  #   v3: runtime posture (cap drop=ALL + adds, no-new-privileges, init) - phase 2
  # The +sinkhole suffix is the var.sinkhole hook described above; the +hc
  # suffix is the analogous var.healthcheck_ping_param hook (see the imap
  # marker) that keeps the HEALTHCHECK_PING_URL secret in step with whether
  # monitoring is enabled. smtp-out was already re-registered clean at v3 by
  # the queue/sinkhole work after monitoring was removed, so appending +hc is a
  # no-op for the current (monitoring-off) state and only future-proofs this
  # tier against a re-enable.
  input = "${var.sinkhole ? "smtp-queue-mount-v3+sinkhole" : "smtp-queue-mount-v3"}${var.healthcheck_ping_param != "" ? "+hc" : ""}"
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

    # SINKHOLE_ENABLED is appended conditionally so the env-var list
    # is identical between sinkhole-on and sinkhole-off task defs in
    # any environment where the flag is permanently false. generate-config.sh
    # checks the env var at runtime and adds the sinkhole.test mailertable
    # entry only when true. See docs/0.9.x/sinkhole-test-harness-plan.md.
    environment = concat([
      { name = "TIER", value = "smtp-out" },
      { name = "CERT_DOMAIN", value = var.control_domain },
      { name = "AWS_REGION", value = var.region },
      { name = "COGNITO_CLIENT_ID", value = var.client_id },
      { name = "COGNITO_POOL_ID", value = var.user_pool_id },
      { name = "NETWORK_CIDR", value = var.cidr_block },
      { name = "SQS_QUEUE_URL", value = aws_sqs_queue.tier["smtp-out"].url },
      { name = "IMAP_INTERNAL_HOST", value = "${aws_service_discovery_service.imap.name}.${aws_service_discovery_private_dns_namespace.mail.name}" },
      ], var.sinkhole ? [
      { name = "SINKHOLE_ENABLED", value = "true" },
    ] : [])

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

    # Runtime posture, phase 2 (see the imap task def for the full
    # rationale). smtp-out runs sendmail + dovecot submission + opendkim;
    # opendkim drops to opendkim:opendkim (UserID in opendkim.conf) and
    # dovecot submission-login chroots, so it needs the full set. Dev soak
    # should TIGHTEN this.
    #   NET_BIND_SERVICE  dovecot binds 465/587 (submission)
    #   SETUID, SETGID    sendmail delivery agents; dovecot workers; opendkim
    #                     drops to its own uid
    #   CHOWN             sync-users.sh; opendkim key chown; mqueue root:mail
    #   DAC_OVERRIDE, FOWNER  user provisioning
    #   KILL              root masters signal non-root children
    #   SYS_CHROOT        dovecot submission-login chroots by default
    linuxParameters = {
      initProcessEnabled = true
      capabilities = {
        drop = ["ALL"]
        add = [
          "CHOWN",
          "DAC_OVERRIDE",
          "FOWNER",
          "KILL",
          "NET_BIND_SERVICE",
          "SETGID",
          "SETUID",
          "SYS_CHROOT",
        ]
      }
    }

    dockerSecurityOptions = ["no-new-privileges"]

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
