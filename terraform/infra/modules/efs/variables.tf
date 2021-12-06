variable "vpc" {
  type        = map
  description = "VPC"
}

variable "private_subnets" {
  type        = list(map)
  description = "Private subnets"
}