variable "name" {
  type = string
}

variable "runtime" {
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

variable "documents" {}