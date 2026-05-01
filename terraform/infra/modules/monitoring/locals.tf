locals {
  # Phase 4 of docs/0.9.0/build-deploy-simplification-plan.md.
  # When /cabal/deployed_image_tag is the bootstrap sentinel, the ECR
  # repos for the monitoring tiers are still empty, so each task def
  # points at a public-ECR placeholder so the cluster comes up cleanly
  # on the very first apply. The phase 1 lifecycle clauses on each
  # aws_ecs_task_definition keep subsequent app.yml deploys from being
  # clobbered by a topology-only Terraform apply.
  placeholder_image_tag = "bootstrap-placeholder"
  placeholder_image     = "public.ecr.aws/nginx/nginx:stable"

  service_image = {
    uptime-kuma         = var.image_tag == local.placeholder_image_tag ? local.placeholder_image : "${var.kuma_ecr_repository_url}:${var.image_tag}"
    ntfy                = var.image_tag == local.placeholder_image_tag ? local.placeholder_image : "${var.ntfy_ecr_repository_url}:${var.image_tag}"
    healthchecks        = var.image_tag == local.placeholder_image_tag ? local.placeholder_image : "${var.healthchecks_ecr_repository_url}:${var.image_tag}"
    prometheus          = var.image_tag == local.placeholder_image_tag ? local.placeholder_image : "${var.prometheus_ecr_repository_url}:${var.image_tag}"
    alertmanager        = var.image_tag == local.placeholder_image_tag ? local.placeholder_image : "${var.alertmanager_ecr_repository_url}:${var.image_tag}"
    grafana             = var.image_tag == local.placeholder_image_tag ? local.placeholder_image : "${var.grafana_ecr_repository_url}:${var.image_tag}"
    cloudwatch-exporter = var.image_tag == local.placeholder_image_tag ? local.placeholder_image : "${var.cloudwatch_exporter_ecr_repository_url}:${var.image_tag}"
    blackbox-exporter   = var.image_tag == local.placeholder_image_tag ? local.placeholder_image : "${var.blackbox_exporter_ecr_repository_url}:${var.image_tag}"
    node-exporter       = var.image_tag == local.placeholder_image_tag ? local.placeholder_image : "${var.node_exporter_ecr_repository_url}:${var.image_tag}"
  }
}
