data "aws_caller_identity" "current" {}

variable "user_pool_id" {
  type = string
}

variable "user_pool_client_id" {
  type = string
}

variable "region" {
  type = string
}

variable "control_domain" {
  type = string
}

variable "relay_ips" {
  type = list(string)
}

variable "cert_arn" {
  type = string
}

variable "zone_id" {
  type = string
}

variable "domains" {
  type = list
}