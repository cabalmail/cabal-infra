locals {
  bit_offsets = [0, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4]
  bit_offset  = local.bit_offsets[length(var.az_list) * 2]
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

variable "zone_id" {
  type        = string
  description = "Public zone for control domain."
}

variable "use_nat_instance" {
  type        = bool
  description = "Use EC2 NAT instances instead of NAT Gateway."
  default     = false
}

variable "nat_instance_type" {
  type        = string
  description = "Instance type for NAT instances (when use_nat_instance = true)."
  default     = "t3.micro"
}