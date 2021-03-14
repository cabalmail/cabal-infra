variable "repo" {
  description "This repository. Used for tagging resources."
}

variable "vpc" {
  description = "VPC for the load balancer."
}

variable "public_subnets" {
  description = "Subnets for load balancer targets."
}

variable "cert_key" {
  type        = string
  description = "Private key for import to ACM"
}

variable "cert_body" {
  type        = string
  description = "Certificate for import to ACM"
}

variable "cert_chain" {
  type        = string
  description = "Certificate chain for import to ACM"
}