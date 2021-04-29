variable "control_domain" {
  description = "Root domain for infrastructure."
}

variable "repo" {
  description = "This repository. Used for tagging resources."
}

variable "vpc" {
  description = "VPC for the load balancer."
}

variable "public_subnets" {
  description = "Subnets for load balancer targets."
}