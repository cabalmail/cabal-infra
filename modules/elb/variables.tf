variable "vpc" {
  description = "VPC for the load balancer."
}

variable "private_subnets" {
  description = "Subnets for load balancer targets."
}

variable "public_subnets" {
  description = "Subnets for load balancer."
}