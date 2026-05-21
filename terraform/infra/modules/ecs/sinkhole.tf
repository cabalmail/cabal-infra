/**
* SMTP sinkhole test fixture.
*
* See docs/0.9.x/sinkhole-test-harness-plan.md. Provisions a tiny
* asyncio SMTP listener whose response shape is controlled by an SSM
* parameter (/cabal/sinkhole_mode). Reachable only from inside the
* VPC via Cloud Map (sinkhole.cabal.internal); never fronted by the
* NLB. The whole tier is gated on var.sinkhole and refused in prod
* by both a parent-stack variable validation and the precondition
* on the task definition below.
*
* Operator workflow:
*   aws ssm put-parameter --name /cabal/sinkhole_mode --value defer  --overwrite
*   ...drive smtp-out and observe queue...
*   aws ssm put-parameter --name /cabal/sinkhole_mode --value accept --overwrite
*
* The listener re-reads the parameter on each new connection (cached
* 30 s) so a flip takes effect on the next retry attempt.
*/

# -- Security group --------------------------------------------
#
# Port 25 from VPC CIDR only. Not in local.tiers because the sinkhole
# does not share the SQS/SNS reconfigure path, public NLB target groups,
# or the standard ingress posture of the mail tiers.

resource "aws_security_group" "sinkhole" {
  count       = var.sinkhole ? 1 : 0
  name        = "cabal-ecs-sinkhole-sg"
  description = "Allow sinkhole inbound port 25 from VPC"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "sinkhole_egress" {
  count             = var.sinkhole ? 1 : 0
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-egress-sgr
  description       = "Allow all outgoing (SSM API calls + ECR pulls)"
  security_group_id = aws_security_group.sinkhole[0].id
}

resource "aws_security_group_rule" "sinkhole_ingress_vpc" {
  count             = var.sinkhole ? 1 : 0
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 25
  to_port           = 25
  cidr_blocks       = [var.cidr_block]
  description       = "Allow incoming port 25 sinkhole from VPC"
  security_group_id = aws_security_group.sinkhole[0].id
}

# -- CloudWatch log group --------------------------------------

resource "aws_cloudwatch_log_group" "sinkhole" {
  count             = var.sinkhole ? 1 : 0
  name              = "/ecs/cabal-sinkhole"
  retention_in_days = 30
}

# -- SSM Parameter for runtime mode -----------------------------
#
# Operators flip this value via the AWS console or CLI; the listener
# re-reads it on each new connection (30s cache).

resource "aws_ssm_parameter" "sinkhole_mode" {
  count       = var.sinkhole ? 1 : 0
  name        = "/cabal/sinkhole_mode"
  description = "Sinkhole response mode: defer, bounce, accept, accept-log, greylist. See docs/0.9.x/sinkhole-test-harness-plan.md."
  type        = "String"
  value       = "defer"

  lifecycle {
    ignore_changes = [value]
  }
}

# -- Task role: ssm:GetParameter for /cabal/sinkhole_mode only --
#
# Dedicated task role; the standard ecs_task role grants DynamoDB,
# Cognito, and SQS access that the sinkhole has no business with.

resource "aws_iam_role" "sinkhole_task" {
  count = var.sinkhole ? 1 : 0
  name  = "cabal-ecs-sinkhole-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "sinkhole_task" {
  count       = var.sinkhole ? 1 : 0
  name        = "cabal-ecs-sinkhole-task-access"
  description = "Runtime permissions for the sinkhole listener: read /cabal/sinkhole_mode and open an SSM session for exec."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
        ]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/sinkhole_mode"
      },
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sinkhole_task" {
  count      = var.sinkhole ? 1 : 0
  role       = aws_iam_role.sinkhole_task[0].name
  policy_arn = aws_iam_policy.sinkhole_task[0].arn
}

# -- Cloud Map registration ------------------------------------
#
# Address: sinkhole.cabal.internal (in the existing private DNS
# namespace). The lifecycle + orphan-reconciliation pattern mirrors
# the imap registration in service_discovery.tf; see that file for
# the full rationale.

resource "aws_service_discovery_service" "sinkhole" {
  count = var.sinkhole ? 1 : 0
  name  = "sinkhole"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.mail.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  lifecycle {
    ignore_changes = [health_check_custom_config]
  }
}

# Orphan-reconciliation pattern: drains the ECS service on Cloud Map
# replace so DeleteService does not reject because of registered
# instances, and force-redeploys so the fresh task registers against
# the new registry ARN. See service_discovery.tf:79 for the imap
# version and the underlying incident notes.
resource "terraform_data" "sinkhole_cloud_map_lifecycle" {
  count = var.sinkhole ? 1 : 0

  triggers_replace = [
    aws_service_discovery_service.sinkhole[0].id,
    var.quiesced,
  ]

  input = {
    cluster_name     = aws_ecs_cluster.mail.name
    ecs_service_name = aws_ecs_service.sinkhole[0].name
    region           = var.region
    desired_count    = var.quiesced ? 0 : 1
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -eu
      echo "[sinkhole-cm-lifecycle] draining ${self.input.ecs_service_name} before Cloud Map service is destroyed"
      aws --region ${self.input.region} ecs update-service \
        --cluster ${self.input.cluster_name} \
        --service ${self.input.ecs_service_name} \
        --desired-count 0 \
        --no-cli-pager >/dev/null
      aws --region ${self.input.region} ecs wait services-stable \
        --cluster ${self.input.cluster_name} \
        --services ${self.input.ecs_service_name}
    EOT
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      echo "[sinkhole-cm-lifecycle] restoring ${self.input.ecs_service_name} (desired=${self.input.desired_count}) and forcing redeploy"
      aws --region ${self.input.region} ecs update-service \
        --cluster ${self.input.cluster_name} \
        --service ${self.input.ecs_service_name} \
        --desired-count ${self.input.desired_count} \
        --force-new-deployment \
        --no-cli-pager >/dev/null
    EOT
  }

  depends_on = [aws_ecs_service.sinkhole]
}

# -- Task definition -------------------------------------------
#
# Image is resolved via local.tier_image["sinkhole"] which falls
# back to a public placeholder when /cabal/deployed_image_tag is
# the bootstrap sentinel - same pattern as the other tiers.

resource "aws_ecs_task_definition" "sinkhole" {
  count                    = var.sinkhole ? 1 : 0
  family                   = "cabal-sinkhole"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.sinkhole_task[0].arn

  container_definitions = jsonencode([{
    name      = "sinkhole"
    image     = local.tier_image["sinkhole"]
    essential = true

    memoryReservation = 64
    memory            = 128

    portMappings = [
      { containerPort = 25, protocol = "tcp" },
    ]

    environment = [
      { name = "TIER", value = "sinkhole" },
      { name = "AWS_REGION", value = var.region },
      { name = "SINKHOLE_MODE_PARAM", value = aws_ssm_parameter.sinkhole_mode[0].name },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.sinkhole[0].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "sinkhole"
        "mode"                  = "non-blocking"
      }
    }
  }])

  # Belt-and-suspenders prod-safety: the parent stack's var.sinkhole
  # validation block already refuses true + environment == "prod" at
  # plan time. This precondition is the documented contract at the
  # resource level - if the validation is ever loosened, this still
  # fails the plan before any prod resource is touched.
  lifecycle {
    ignore_changes = [container_definitions]

    precondition {
      condition     = !(var.sinkhole && var.environment == "prod")
      error_message = "Sinkhole tier must never run in prod. See docs/0.9.x/sinkhole-test-harness-plan.md."
    }
  }
}

# -- ECS service -----------------------------------------------

resource "aws_ecs_service" "sinkhole" {
  count           = var.sinkhole ? 1 : 0
  name            = "cabal-sinkhole"
  cluster         = aws_ecs_cluster.mail.id
  task_definition = aws_ecs_task_definition.sinkhole[0].arn
  desired_count   = var.quiesced ? 0 : 1

  enable_execute_command = true

  # Single task; no autoscaling. A test fixture under intentional
  # load is not the goal.
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnets[*].id
    security_groups = [aws_security_group.sinkhole[0].id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.sinkhole[0].arn
  }

  depends_on = [aws_ecs_cluster_capacity_providers.mail]

  # See aws_ecs_service.imap for rationale: app.yml deploy script
  # rolls the service out-of-band; Terraform must not roll it back.
  lifecycle {
    ignore_changes = [task_definition]
  }
}
