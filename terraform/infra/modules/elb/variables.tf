variable "control_domain" {
  description = "Root domain for infrastructure."
}

variable "vpc" {
  type        = map
  description = "VPC for the load balancer."
}

variable "public_subnets" {
  type        = list(map)
  description = "Subnets for load balancer targets."
}

variable "zone_id" {
  type        = string
  description = "Route 53 Zone ID for control domain"
}

variable "cert_arn" {
  type        = string
  description = "ARN of AWS Certificate Manager certificate."
}