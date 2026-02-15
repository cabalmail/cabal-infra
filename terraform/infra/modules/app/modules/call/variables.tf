variable "name" {
  type = string
}

variable "runtime" {
  type = string
}

variable "layer_arns" {
  type = list(string)
}

variable "type" {
  type = string
}

variable "gateway_id" {
  type = string
}

variable "root_resource_id" {
  type = string
}

variable "region" {
  type = string
}

variable "method" {
  type = string
}

variable "account" {
  type = string
}

variable "authorizer" {
  type = string
}

variable "control_domain" {
  type = string
}

variable "relay_ips" {
  type = list(string)
}

variable "domains" {
  type = list
}

variable "repo" {
  type        = string
  description = "Repo tag value for SSM run command target."
}

variable "bucket" {
  type = string
}

variable "memory" {
  type    = number
  default = 128
}

variable "address_changed_topic_arn" {
  type        = string
  description = "ARN of the SNS topic for address change notifications to ECS containers."
}