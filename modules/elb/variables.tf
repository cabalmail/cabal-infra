variable "control_domain" {
  description = "Root domain for infrastructure."
}

variable "vpc" {
  description = "VPC for the load balancer."
}

variable "public_subnets" {
  description = "Subnets for load balancer targets."
}

variable "zone_id" {
  description = "Route 53 Zone ID for control domain"
}

variable "cert_arn" {
  type = string
}