variable "name" {
  type = string
}

variable "runtime" {
  type = string
}

variable "region" {
  type = string
}

variable "account" {
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

variable "method" {
  type = string
}

variable "call_path" {
  type = string
}

variable "repo" {
  type = string
}
