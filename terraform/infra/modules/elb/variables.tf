variable "control_domain" {
  type        = string
  description = "Root domain for infrastructure."
}

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

variable "cert_arn" {
  type        = string
  description = "ARN of AWS Certificate Manager certificate."
}