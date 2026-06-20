locals {
  # CloudFront emits CloudWatch metrics only in us-east-1 regardless of
  # where the rest of the infra is deployed. This is an AWS API
  # constraint, not a deployment-region choice - the SDK has no way to
  # ask for AWS/CloudFront metrics in any other region. Anywhere the
  # cloudwatch_exporter has to call the CloudFront-bearing CloudWatch
  # endpoint, we point at this constant rather than hard-coding the
  # string. Everything else (logs, networking, IAM) uses var.region.
  cloudfront_metrics_region = "us-east-1"

  # Phase 4 of docs/0.9.x/build-deploy-simplification-plan.md.
  # When a tier's deployed-image-tag SSM parameter resolves to the
  # bootstrap sentinel, the ECR repos for the monitoring tiers are
  # still empty, so that task def points at a public-ECR placeholder so
  # the cluster comes up cleanly on the very first apply. The phase 1
  # lifecycle clauses on each aws_ecs_task_definition keep subsequent
  # app.yml deploys from being clobbered by a topology-only Terraform
  # apply. Tags arrive per tier (var.image_tags, one SSM key per tier -
  # see docs/0.10.x/per-tier-docker-deploy-plan.md) because app.yml
  # only rebuilds the tiers whose inputs changed.
  placeholder_image_tag = "bootstrap-placeholder"
  placeholder_image     = "public.ecr.aws/nginx/nginx:stable"

  service_repo = {
    uptime-kuma         = var.kuma_ecr_repository_url
    ntfy                = var.ntfy_ecr_repository_url
    healthchecks        = var.healthchecks_ecr_repository_url
    prometheus          = var.prometheus_ecr_repository_url
    alertmanager        = var.alertmanager_ecr_repository_url
    grafana             = var.grafana_ecr_repository_url
    cloudwatch-exporter = var.cloudwatch_exporter_ecr_repository_url
    blackbox-exporter   = var.blackbox_exporter_ecr_repository_url
    node-exporter       = var.node_exporter_ecr_repository_url
  }

  service_image = {
    for tier, repo in local.service_repo :
    tier => var.image_tags[tier] == local.placeholder_image_tag ? local.placeholder_image : "${repo}:${var.image_tags[tier]}"
  }
}
