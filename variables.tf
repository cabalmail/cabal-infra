variable "aws_primary_region" {
  type        = string
  description = "AWS region in which to provision primary infrastructure. Default us-west-1."
  default     = "us-west-1"
}

variable "aws_secondary_region" {
  type        = string
  description = "AWS region in which to provision secondary infrastructure. Default us-east-1."
  default     = "us-east-1"
}

variable "create_secondary" {
  type        = bool
  description = "Whether to create infrastructure in a second region. Recommended for prod. Default false."
  default     = false
}

variable "primary_cidr_block" {
  type        = string
  description = "CIDR block for the VPC in the primary region."
}

variable "secondary_cidr_block" {
  type        = string
  description = "CIDR block for the VPC in the secondary region."
}

variable "az_count" {
  type        = number
  description = "Number of Availability Zones to use. 3 recommended for prod. Default 1."
  default     = 1
}