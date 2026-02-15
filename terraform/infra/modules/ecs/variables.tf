/**
* Input variables for the ECS module.
*/

# ── Networking ─────────────────────────────────────────────────

variable "private_subnets" {
  type        = list(any)
  description = "Private subnets for ECS tasks and EC2 instances."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID."
}

variable "cidr_block" {
  type        = string
  description = "VPC CIDR block for private ingress rules."
}

variable "region" {
  type        = string
  description = "AWS region."
}

# ── Domain / TLS ───────────────────────────────────────────────

variable "control_domain" {
  type        = string
  description = "Control domain (e.g. example.com). Used for CERT_DOMAIN env var."
}

# ── Data stores ────────────────────────────────────────────────

variable "table_arn" {
  type        = string
  description = "ARN of the cabal-addresses DynamoDB table."
}

variable "efs_id" {
  type        = string
  description = "EFS file system ID for the mailstore."
}

# ── Cognito ────────────────────────────────────────────────────

variable "user_pool_arn" {
  type        = string
  description = "ARN of the Cognito user pool."
}

variable "user_pool_id" {
  type        = string
  description = "ID of the Cognito user pool."
}

variable "client_id" {
  type        = string
  description = "Cognito app client ID."
}

# ── Container images ──────────────────────────────────────────

variable "ecr_repository_urls" {
  type        = map(string)
  description = "Map of tier name to ECR repository URL (e.g. {imap = '...', smtp-in = '...', smtp-out = '...'})."
}

variable "image_tag" {
  type        = string
  description = "Docker image tag (git SHA or 'latest')."
  default     = "latest"
}

# ── Secrets ────────────────────────────────────────────────────

variable "master_password" {
  type        = string
  description = "Master password for Lambda-to-IMAP access."
  sensitive   = true
}

# ── Instance sizing ───────────────────────────────────────────

variable "instance_type" {
  type        = string
  description = "EC2 instance type for ECS container instances."
  default     = "t3.small"
}
