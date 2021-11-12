locals {
  bit_offsets = [ 0,1,2,2,3,3,3,3,4,4,4,4,4,4,4,4 ]
  bit_offset  = local.bit_offsets[length(var.az_list)*2]
}

variable "cidr_block" {
  type        = string
  description = "CIDR for the VPC."
}

variable "az_list" {
  type        = list(string)
  description = "List of availability zones to use."
}

variable "control_domain" {
  type        = string
  description = "Control domain."
}