data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

variable "user_pool_id" {
  type        = string
  description = "ID of the Cognito user pool."
}

variable "user_pool_client_id" {
  type        = string
  description = "Client ID for authenticating with the Cognito user pool."
}

variable "region" {
  type        = string
  description = "The AWS region."
}

variable "control_domain" {
  type        = string
  description = "The control domain."
}

variable "relay_ips" {
  type        = list(string)
  description = "Egress IP addresses."
}

variable "cert_arn" {
  type        = string
  description = "ARN for the AWS Certificate Manager certificate for the control domain."
}

variable "zone_id" {
  type        = string
  description = "Route 53 zone ID for the control domain."
}

variable "private_zone_id" {
  type        = string
  description = "Route 53 private zone ID for the control domain. The admin CNAME is mirrored here so VPC-internal callers (e.g. Kuma) can resolve admin.<control-domain>."
}

variable "domains" {
  type        = list(any)
  description = "List of email domains."
}

variable "repo" {
  type        = string
  description = "Repo tag value for SSM run command target."
}

variable "dev_mode" {
  type        = bool
  description = "If true, forces Cloudfront to non-caching configuration."
}

variable "stage_name" {
  type        = string
  default     = "prod"
  description = "Name for the API Gateway stage. Default: prod."
}

variable "bucket" {
  type        = string
  description = "Name of s3 bucket"
}

variable "bucket_domain_name" {
  type        = string
  description = "Domain name of s3 bucket"
}

variable "origin" {
  type        = string
  description = "S3 Origin ID for CloudFront"
}

variable "address_changed_topic_arn" {
  type        = string
  description = "ARN of the SNS topic for address change notifications to ECS containers."
}

variable "admin_group_name" {
  type        = string
  description = "Name of the Cognito admin group."
}

variable "dmarc_healthcheck_ping_param" {
  type        = string
  description = "SSM Parameter Store name holding the Healthchecks ping URL for the process_dmarc Lambda. Empty string disables the heartbeat."
  default     = ""
}

variable "invitation_required" {
  type        = bool
  description = "When true, the React signup form renders the invitation-code field and requires a non-empty value. Plumbed into /config.js so the client can mirror the server-side check_invite gate."
  default     = false
}

variable "monitoring" {
  type        = bool
  description = "Mirror of the top-level var.monitoring. When true, /config.js advertises the monitoring stack so the admin app's Nav can surface Uptime Kuma, Healthchecks, and Grafana entries (which target uptime/heartbeat/metrics.<control-domain>)."
  default     = false
}
