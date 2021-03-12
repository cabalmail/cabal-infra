variable "aws_region" {
  type        = string
  description = "AWS region in which to provision infrastructure. Default us-west-1."
  default     = "us-west-1"
}

variable "cidr_block" {
  type        = string
  description = "CIDR block for the VPC."
}

variable "az_count" {
  type        = number
  description = "Number of Availability Zones to use. 3 recommended for prod. Default 1."
  default     = 1
}