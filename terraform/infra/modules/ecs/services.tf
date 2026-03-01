/**
* ECS services and auto-scaling policies.
*
* IMAP: Hard-capped at one container. Dovecot has concurrency issues with
* shared Maildir over EFS, so there must never be more than one IMAP task.
*
* SMTP-IN / SMTP-OUT: Scale based on CPU utilization. OpenDKIM on the
* SMTP-OUT tier is the most likely bottleneck.
*/

# ── IMAP service ──────────────────────────────────────────────

resource "aws_ecs_service" "imap" {
  name            = "cabal-imap"
  cluster         = aws_ecs_cluster.mail.id
  task_definition = aws_ecs_task_definition.imap.arn
  desired_count   = 1

  enable_execute_command = true

  health_check_grace_period_seconds = var.health_check_grace_period

  # No extra task during deploy — only one IMAP container at a time.
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnets[*].id
    security_groups = [aws_security_group.tier["imap"].id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tier["imap"].arn
    container_name   = "imap"
    container_port   = 143
  }

  service_registries {
    registry_arn = aws_service_discovery_service.imap.arn
  }

  depends_on = [aws_ecs_cluster_capacity_providers.mail]
}

# ── SMTP-IN service ───────────────────────────────────────────

resource "aws_ecs_service" "smtp_in" {
  name            = "cabal-smtp-in"
  cluster         = aws_ecs_cluster.mail.id
  task_definition = aws_ecs_task_definition.smtp_in.arn
  desired_count   = 1

  enable_execute_command = true

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnets[*].id
    security_groups = [aws_security_group.tier["smtp-in"].id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tier["relay"].arn
    container_name   = "smtp-in"
    container_port   = 25
  }

  depends_on = [aws_ecs_cluster_capacity_providers.mail]
}

# ── SMTP-OUT service ──────────────────────────────────────────

resource "aws_ecs_service" "smtp_out" {
  name            = "cabal-smtp-out"
  cluster         = aws_ecs_cluster.mail.id
  task_definition = aws_ecs_task_definition.smtp_out.arn
  desired_count   = 1

  enable_execute_command = true

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnets[*].id
    security_groups = [aws_security_group.tier["smtp-out"].id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tier["submission"].arn
    container_name   = "smtp-out"
    container_port   = 25
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tier["starttls"].arn
    container_name   = "smtp-out"
    container_port   = 587
  }

  depends_on = [aws_ecs_cluster_capacity_providers.mail]
}

# ── Auto-scaling: SMTP-IN ────────────────────────────────────

resource "aws_appautoscaling_target" "smtp_in" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.mail.name}/${aws_ecs_service.smtp_in.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "smtp_in_cpu" {
  name               = "cabal-smtp-in-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.smtp_in.resource_id
  scalable_dimension = aws_appautoscaling_target.smtp_in.scalable_dimension
  service_namespace  = aws_appautoscaling_target.smtp_in.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

# ── Auto-scaling: SMTP-OUT ───────────────────────────────────

resource "aws_appautoscaling_target" "smtp_out" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.mail.name}/${aws_ecs_service.smtp_out.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "smtp_out_cpu" {
  name               = "cabal-smtp-out-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.smtp_out.resource_id
  scalable_dimension = aws_appautoscaling_target.smtp_out.scalable_dimension
  service_namespace  = aws_appautoscaling_target.smtp_out.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 70.0
  }
}
