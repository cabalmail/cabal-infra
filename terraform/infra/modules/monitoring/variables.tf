variable "control_domain" {
  type        = string
  description = "Control domain; used to derive uptime.<control-domain> and ntfy.<control-domain>."
}

variable "region" {
  type        = string
  description = "AWS region."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID in which the monitoring resources run."
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR block. Used to allow the ALB to reach the Kuma and ntfy tasks."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs for the monitoring ALB."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the Kuma and ntfy ECS tasks."
}

variable "zone_id" {
  type        = string
  description = "Route 53 public zone ID for the control domain."
}

variable "private_zone_id" {
  type        = string
  description = "Route 53 private zone ID for the control domain. uptime/ntfy aliases are mirrored here so VPC-internal callers (e.g. Kuma) can resolve them."
}

variable "cert_arn" {
  type        = string
  description = "ARN of the wildcard ACM certificate for *.<control-domain>."
}

variable "ecs_cluster_id" {
  type        = string
  description = "ID of the ECS cluster that hosts Uptime Kuma and ntfy."
}

variable "ecs_cluster_capacity_provider" {
  type        = string
  description = "Name of the ECS capacity provider to place the monitoring tasks on."
}

variable "efs_id" {
  type        = string
  description = "EFS file system ID used for Kuma and ntfy persistent state."
}

variable "tier_log_group_names" {
  type        = map(string)
  description = "Map of mail-tier CloudWatch log group names keyed by tier (imap | smtp-in | smtp-out). Phase 4 §2 attaches metric filters to these."
}

variable "kuma_ecr_repository_url" {
  type        = string
  description = "ECR repository URL for the uptime-kuma image."
}

variable "ntfy_ecr_repository_url" {
  type        = string
  description = "ECR repository URL for the ntfy image."
}

variable "healthchecks_ecr_repository_url" {
  type        = string
  description = "ECR repository URL for the Healthchecks image."
}

variable "prometheus_ecr_repository_url" {
  type        = string
  description = "ECR repository URL for the Prometheus image (Phase 3)."
}

variable "alertmanager_ecr_repository_url" {
  type        = string
  description = "ECR repository URL for the Alertmanager image (Phase 3)."
}

variable "grafana_ecr_repository_url" {
  type        = string
  description = "ECR repository URL for the Grafana image (Phase 3)."
}

variable "cloudwatch_exporter_ecr_repository_url" {
  type        = string
  description = "ECR repository URL for the cloudwatch_exporter image (Phase 3)."
}

variable "blackbox_exporter_ecr_repository_url" {
  type        = string
  description = "ECR repository URL for the blackbox_exporter image (Phase 3)."
}

variable "node_exporter_ecr_repository_url" {
  type        = string
  description = "ECR repository URL for the node_exporter image (Phase 3)."
}

variable "environment" {
  type        = string
  description = "Environment name (prod/stage/dev). Used as an external label on Prometheus metrics so multi-env Grafana dashboards can filter."
}

variable "image_tag" {
  type        = string
  description = "Image tag to deploy for the monitoring services, shared with the mail tiers."
}

variable "user_pool_id" {
  type        = string
  description = "Cognito user pool ID used to authenticate the Kuma UI at the ALB."
}

variable "user_pool_arn" {
  type        = string
  description = "Cognito user pool ARN used by the ALB authenticate action."
}

variable "user_pool_domain" {
  type        = string
  description = "Cognito hosted UI domain (without the .auth.<region>.amazoncognito.com suffix)."
}

variable "lambda_bucket" {
  type        = string
  description = "S3 bucket holding the alert_sink Lambda zip (built by build-api.sh)."
}

variable "ntfy_topic" {
  type        = string
  description = "ntfy topic name that alert_sink publishes to. Must match the topic the admin user has publish access on."
  default     = "alerts"
}

variable "mail_domains" {
  type        = list(string)
  description = "List of Cabalmail-hosted mail domains. The first entry is used as the From: domain for Healthchecks-originated mail (control_domain typically has no MX at the apex, so noreply@<control-domain> gets rejected by sendmail's sender-domain check)."
}

variable "healthchecks_registration_open" {
  type        = bool
  description = "Whether the Healthchecks signup form is open. True at bootstrap to let the operator sign up the first user via the magic-link flow; false the rest of the time."
  default     = false
}
