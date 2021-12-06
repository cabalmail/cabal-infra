variable "vpc" {
  type        = map
  description = "VPC"
}

variable "private_subnets" {
  type        = list(string)
  description = "Private subnets"
}