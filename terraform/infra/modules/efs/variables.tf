variable "vpc" {
  type        = map
  description = "VPC"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets"
}