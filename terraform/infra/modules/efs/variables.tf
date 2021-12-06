variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "vpc_cidr_block" {
  type        = string
  description = "CIDR block for the VPC"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets"
}