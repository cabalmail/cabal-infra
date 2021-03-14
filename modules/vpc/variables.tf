variable "repo" {
  type        = string
  description = "This repository. Used for tagging resources."
}

variable "cidr_block" {
  type        = string
  description = "CIDR for the VPC."
}

variable "az_list" {
  type        = list(string)
  description = "List of availability zones to use."
}