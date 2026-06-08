/**
* Input variables for the ECS module.
*/

# -- Networking -------------------------------------------------

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

variable "login_trusted_cidrs" {
  type        = list(string)
  description = "Source CIDRs Dovecot treats as already-secured for auth (the NLB public-subnet CIDRs). Joined into the LOGIN_TRUSTED_NETWORKS env on the imap/smtp-out task defs; with disable_plaintext_auth = yes the entrypoint uses these and falls back to cidr_block if empty (fail open, no lockout). Phase 4 of docs/0.10.x/container-runtime-hardening-plan.md."
  default     = []
}

variable "region" {
  type        = string
  description = "AWS region."
}

# -- Domain / TLS -----------------------------------------------

variable "control_domain" {
  type        = string
  description = "Control domain (e.g. example.com). Used for CERT_DOMAIN env var."
}

# -- Data stores ------------------------------------------------

variable "table_arn" {
  type        = string
  description = "ARN of the cabal-addresses DynamoDB table."
}

variable "efs_id" {
  type        = string
  description = "EFS file system ID for the mailstore."
}

variable "smtp_queue_access_point_id" {
  type        = string
  description = "EFS access point id for the shared smtp-out sendmail MTA queue (mounted at /var/spool/mqueue in the smtp-out task)."
}

# -- Cognito ----------------------------------------------------

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

# -- Container images ------------------------------------------

variable "ecr_repository_urls" {
  type        = map(string)
  description = "Map of tier name to ECR repository URL (e.g. {imap = '...', smtp-in = '...', smtp-out = '...'})."
}

variable "image_tag" {
  type        = string
  description = "Docker image tag (e.g. sha-abc12345)."
}

# -- Secrets ----------------------------------------------------
# (The IMAP master password reaches the containers via the SSM parameter
# /cabal/master_password, referenced directly in the task definition's
# valueFrom - it was never consumed as a module variable.)

# -- Instance sizing -------------------------------------------

variable "instance_type" {
  type        = string
  description = "EC2 instance type for ECS container instances."
  default     = "m6g.medium"
}

# -- Health checks --------------------------------------------

variable "health_check_grace_period" {
  type        = number
  description = "Seconds ECS ignores target-group health failures after a task starts."
  default     = 300
}

variable "deregistration_delay" {
  type        = number
  description = "Seconds the NLB waits for in-flight requests before deregistering a target."
  default     = 30
}

variable "unhealthy_threshold" {
  type        = number
  description = "Consecutive failed NLB health checks before a target is marked unhealthy."
  default     = 2
}

# -- Heartbeat monitoring --------------------------------------

variable "healthcheck_ping_param" {
  type        = string
  description = "SSM Parameter Store name holding the Healthchecks ping URL for the reconfigure.sh loop. Empty string disables the heartbeat (used when var.monitoring is false in the parent stack)."
  default     = ""
}

# -- Quiesce ----------------------------------------------------

variable "quiesced" {
  type        = bool
  description = "When true, set ECS service desired_count and the ECS-instance ASG to zero. Capacity-provider managed termination protection and ASG instance scale-in protection are also disabled so the running instance can be terminated."
  default     = false
}

# -- Sinkhole test fixture --------------------------------------

variable "sinkhole" {
  type        = bool
  description = "When true, provision the SMTP sinkhole test fixture (task definition, service, security group, Cloud Map registration, SSM parameter). See docs/0.9.x/sinkhole-test-harness-plan.md. Must never be true in prod; the parent stack's var.sinkhole validation block and the task definition's precondition both refuse that combination."
  default     = false
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. prod, stage, development). Surfaced for the sinkhole precondition; not consumed elsewhere in the ECS module today."
}
