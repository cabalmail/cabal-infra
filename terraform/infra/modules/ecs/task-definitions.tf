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
#
# v4 (phase 6 of docs/0.10.x/container-runtime-hardening-plan.md): forces a
# replacement so the transit_encryption = "ENABLED" added to the mailstore
# volume below actually deploys. A volume edit, like a container_definitions
# edit, only reaches a running task through a marker bump.
# v5 (phase 4 of the same plan): add the LOGIN_TRUSTED_NETWORKS env var (NLB
# public-subnet CIDRs) the entrypoint needs to keep NLB-forwarded logins
# working once disable_plaintext_auth = yes lands in the image.
# v6 (docs/0.11.0/push-notifications.md phase 2): add the PUSH_QUEUE_URL env
# var so the entrypoint can hand the queue URL + task-role credential URI to
# procmail's push-enqueue.sh (sendmail sanitizes the delivery agents' env).
# v7: add the container-level healthCheck (TCP 143). Removing the public
#     IMAPS listener detached the imap target group from the NLB, which
#     stops NLB health checks entirely (targets sit in Target.NotInUse),
#     so without this probe a task that starts but never listens would
#     pass deploys and never be replaced.
# v8 (issue #779, the cleanup #778 deliberately left out): drop the 993
#     port mapping and the LOGIN_TRUSTED_NETWORKS env. With no NLB IMAPS
#     listener there is nothing to forward plain TCP into 143, so the
#     image now sets ssl = required and trusts only loopback; the env
#     would be read no more but the mapping and the wider trust list
#     would keep shipping to running tasks without this bump.
resource "terraform_data" "imap_taskdef_revision_marker" {
  input = var.healthcheck_ping_param != "" ? "imap-taskdef-v8+hc" : "imap-taskdef-v8"
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
      # No 993: the NLB's IMAPS listener was removed in #778 and the image
      # switches the in-container listener off (#779). Consumers dial 143
      # and issue STARTTLS.
      { containerPort = 25, protocol = "tcp" },
    ]

    # In-container TCP probe of the IMAP listener. The imap target group
    # has no NLB listener anymore, and the NLB performs no health checks
    # on a listenerless target group (Target.NotInUse) - this probe is
    # therefore the only "listening", not merely "running", signal. It
    # gates deployments (the circuit breaker below rolls back a task
    # whose container never goes healthy) and replaces a hung-but-alive
    # Dovecot in steady state. interval mirrors the 10s the NLB probe
    # used; startPeriod covers the entrypoint's pre-listen work (cert
    # render, DynamoDB config generation, user sync), matching the
    # service's 120s grace period.
    healthCheck = {
      command     = ["CMD-SHELL", "timeout 5 bash -c '</dev/tcp/127.0.0.1/143'"]
      interval    = 10
      timeout     = 5
      retries     = 3
      startPeriod = 120
    }

    environment = [
      { name = "TIER", value = "imap" },
      { name = "CERT_DOMAIN", value = var.control_domain },
      { name = "AWS_REGION", value = var.region },
      { name = "COGNITO_CLIENT_ID", value = var.client_id },
      { name = "COGNITO_POOL_ID", value = var.user_pool_id },
      { name = "NETWORK_CIDR", value = var.cidr_block },
      { name = "SQS_QUEUE_URL", value = aws_sqs_queue.tier["imap"].url },
      { name = "PUSH_QUEUE_URL", value = aws_sqs_queue.push.url },
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
    #   NET_BIND_SERVICE  dovecot binds 143, sendmail binds 25 (both <1024)
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

  # Phase 6 of docs/0.10.x/container-runtime-hardening-plan.md: encrypt the
  # NFS traffic between the imap task and EFS in transit (it is already
  # encrypted at rest, see modules/efs). No access point: the mailstore is a
  # multi-user tree rooted at "/" with per-user file ownership, so an access
  # point could only be a transparent root-"/" pass-through (iam disabled, no
  # posix_user) - zero gain over transit encryption and a data-path risk if
  # the root were ever set wrong. transit_encryption needs no access point.
  # The smtp-out queue already runs ENABLED on these same hosts.
  volume {
    name = "mailstore"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      root_directory     = "/"
      transit_encryption = "ENABLED"
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
#   v4: drop CHOWN/FOWNER/DAC_OVERRIDE now that the entrypoint skips
#       sync-users.sh on this relay tier - phase 2a.
#   v5: REVERT v4 - restore the full cap set. The v4 drop reached prod
#       without the mandated runtime (mail-flow) validation and the rollout
#       broke: a stale /cabal/deployed_image_tag paired the dropped caps with
#       the PRE-2a image, which still writes /usr/bin/cognito.bash and so
#       needs DAC_OVERRIDE. Backed out to the known-good full set; the drop
#       will be re-attempted only after a real inbound-mail soak through
#       smtp-in in stage. See CHANGELOG 0.10.9.
#   v6: re-drop CHOWN/FOWNER/DAC_OVERRIDE - phase 2a, second attempt. Now a
#       pure Terraform change: the entrypoint cleanups that v4 needed (skip
#       sync-users + cognito.bash on smtp-in) already shipped, so the running
#       image needs none of these at startup, and with no docker rebuild there
#       is no app.yml/infra.yml image-tag race. MUST be soaked in stage with
#       real inbound mail (confirm sendmail relays, no CHOWN errors in the
#       logs) before promoting to prod. See CHANGELOG 0.10.10.
#   v7: EFS relay-queue mount + stopTimeout - the smtp-out queue-persistence
#       pattern (docs/0.9.x/smtp-out-queue-persistence-plan.md) applied to
#       smtp-in, whose mqueue previously lived on the container filesystem
#       and died with the task, silently dropping inbound mail it had
#       already accepted (250) but deferred while the imap tier was
#       mid-deploy.
resource "terraform_data" "smtp_in_taskdef_revision_marker" {
  input = var.healthcheck_ping_param != "" ? "smtp-in-taskdef-v7+hc" : "smtp-in-taskdef-v7"
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

    # Give sendmail up to ~110s to finish an in-flight relay delivery
    # before SIGKILL (supervisord stopwaitsecs=110 in the smtp-in image).
    # The persistent EFS-backed queue below is then the safety net rather
    # than the primary mechanism for surviving deploys. ECS hard-caps
    # stopTimeout at 120 for EC2 launch type.
    stopTimeout = 120

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

    mountPoints = [{
      sourceVolume  = "smtp-in-queue"
      containerPath = "/var/spool/mqueue"
    }]

    # Runtime posture, phase 2 + 2a (see the imap task def for the full
    # rationale). smtp-in is a pure relay: no dovecot (no SYS_CHROOT) and no
    # local delivery (mailertable routes every hosted-domain message to imap
    # over SMTP), and the entrypoint skips sync-users.sh + cognito.bash on it,
    # so it resolves no local OS users and writes no owner-unwritable files at
    # startup. That removed every startup consumer of CHOWN/DAC_OVERRIDE/
    # FOWNER, so they are dropped (2a, second attempt: the first reached prod
    # on a stale image and broke; this is now a Terraform-only change, so no
    # image-tag race). Soak in stage with real inbound mail before prod - if
    # sendmail turns out to need CHOWN at queue/relay time, add just CHOWN back.
    #   NET_BIND_SERVICE  sendmail binds 25
    #   SETUID, SETGID    delivery/queue agents run as mail/smmsp
    #   KILL              root sendmail master signals non-root children
    linuxParameters = {
      initProcessEnabled = true
      capabilities = {
        drop = ["ALL"]
        add = [
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

  # Shared sendmail relay queue on EFS - lets a replaced smtp-in task hand
  # off inbound mail it accepted but could not yet relay (typically while
  # the imap tier is mid-deploy) to whichever sibling task next scans the
  # queue. Mirrors the smtp-out volume below; separate /smtp-in-queue
  # directory so each tier's queue runners only ever process their own
  # tier's mail. IAM auth left disabled for parity with the other EFS
  # mounts (see the smtp-out volume comment).
  volume {
    name = "smtp-in-queue"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.smtp_in_queue_access_point_id
        iam             = "DISABLED"
      }
    }
  }

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
  #   v4: add the LOGIN_TRUSTED_NETWORKS env var (NLB public-subnet CIDRs) for
  #       disable_plaintext_auth = yes - phase 4
  #   v5: add the container-level healthCheck (TCP 465 + 587). The public
  #       submission listeners are gone, which detached both smtp-out
  #       target groups from the NLB and ended its health checks
  #       (Target.NotInUse); see the imap marker's v7 note.
  # The +sinkhole suffix is the var.sinkhole hook described above; the +hc
  # suffix is the analogous var.healthcheck_ping_param hook (see the imap
  # marker) that keeps the HEALTHCHECK_PING_URL secret in step with whether
  # monitoring is enabled. smtp-out was already re-registered clean at v3 by
  # the queue/sinkhole work after monitoring was removed, so appending +hc is a
  # no-op for the current (monitoring-off) state and only future-proofs this
  # tier against a re-enable.
  input = "${var.sinkhole ? "smtp-queue-mount-v5+sinkhole" : "smtp-queue-mount-v5"}${var.healthcheck_ping_param != "" ? "+hc" : ""}"
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

    # In-container TCP probe of both Dovecot submission listeners; the
    # NLB no longer health-checks the submission/starttls target groups
    # (no listener -> Target.NotInUse). See the imap task def for the
    # full rationale. interval mirrors the 30s the NLB probes used;
    # timeout allows for the two sequential 5s connect attempts.
    healthCheck = {
      command     = ["CMD-SHELL", "timeout 5 bash -c '</dev/tcp/127.0.0.1/465' && timeout 5 bash -c '</dev/tcp/127.0.0.1/587'"]
      interval    = 30
      timeout     = 15
      retries     = 3
      startPeriod = 120
    }

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
      { name = "LOGIN_TRUSTED_NETWORKS", value = join(" ", var.login_trusted_cidrs) },
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
