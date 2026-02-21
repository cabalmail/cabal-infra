variable "vpc_id" {
  type        = string
  description = "VPC for the load balancer."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Subnets for load balancer targets."
}

variable "zone_id" {
  type        = string
  description = "Route 53 Zone ID for control domain"
}

variable "control_domain" {
  type        = string
  description = "The control domain"
}

variable "cert_arn" {
  type        = string
  description = "ARN of AWS Certificate Manager certificate."
}

# ── ECS target group ARNs (Phase 7 cutover) ──────────────────
# When set, NLB listeners forward to these ip-type target groups
# instead of the instance-type target groups defined in this module.

variable "ecs_imap_target_group_arn" {
  type        = string
  description = "ARN of the ECS IMAP target group. When set, the IMAP listener forwards here."
  default     = ""
}

variable "ecs_relay_target_group_arn" {
  type        = string
  description = "ARN of the ECS relay target group. When set, the relay listener forwards here."
  default     = ""
}

variable "ecs_submission_target_group_arn" {
  type        = string
  description = "ARN of the ECS submission target group. When set, the submission listener forwards here."
  default     = ""
}

variable "ecs_starttls_target_group_arn" {
  type        = string
  description = "ARN of the ECS STARTTLS target group. When set, the STARTTLS listener forwards here."
  default     = ""
}