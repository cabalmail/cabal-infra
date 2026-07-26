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

# -- ECS target group ARNs ------------------------------------

variable "ecs_imap_target_group_arn" {
  type        = string
  description = "ARN of the ECS IMAP target group."
}

variable "ecs_relay_target_group_arn" {
  type        = string
  description = "ARN of the ECS relay target group."
}

# There are deliberately no submission/starttls target group variables:
# outbound submission is Cabalmail-client-only (the send Lambda reaches
# smtp-out over Cloud Map inside the VPC), so this load balancer carries
# no 465/587 listeners. The submission and starttls target groups live
# on in the ecs module - the service registers with them and their
# health checks drive task replacement - they just have no listeners in
# front of them.

# -- Private DNS -------------------------------------------------

variable "private_zone_id" {
  type        = string
  description = "Route 53 private zone ID for the control domain. Records here let containers inside the VPC resolve tier hostnames (imap, smtp-in, smtp-out) without hitting the public zone."
}