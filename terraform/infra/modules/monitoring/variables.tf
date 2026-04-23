variable "control_domain" {
  type        = string
  description = "Control domain; used to derive uptime.<control-domain>."
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
  description = "VPC CIDR block. Used to allow the ALB to reach the Kuma task."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs for the uptime ALB."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the Kuma ECS task."
}

variable "zone_id" {
  type        = string
  description = "Route 53 public zone ID for the control domain."
}

variable "cert_arn" {
  type        = string
  description = "ARN of the wildcard ACM certificate for *.<control-domain>."
}

variable "ecs_cluster_id" {
  type        = string
  description = "ID of the ECS cluster that hosts Uptime Kuma."
}

variable "ecs_cluster_capacity_provider" {
  type        = string
  description = "Name of the ECS capacity provider to place the Kuma task on."
}

variable "efs_id" {
  type        = string
  description = "EFS file system ID used for Kuma's persistent SQLite state."
}

variable "ecr_repository_url" {
  type        = string
  description = "ECR repository URL for the uptime-kuma image."
}

variable "image_tag" {
  type        = string
  description = "Image tag to deploy for uptime-kuma, shared with the mail tiers."
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
  description = "S3 bucket holding the alert_sms Lambda zip (built by build-api.sh)."
}

variable "on_call_phone_numbers" {
  type        = list(string)
  description = "E.164-formatted phone numbers to receive alert SMS. Empty list disables SMS subscriptions."
  default     = []
}

variable "ses_email_from" {
  type        = string
  description = "From: address used for warning-severity email alerts. Empty disables email fallback."
  default     = ""
}

variable "ses_email_to" {
  type        = string
  description = "To: address for warning-severity email alerts. Empty disables email fallback."
  default     = ""
}
