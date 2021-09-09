variable "private_subnets" {
  description = "Subnets for imap ec2 instances."
}

variable "vpc" {
  description = "VPC for the load balancer."
}

variable "repo" {
  description = "This repository. Used for tagging resources."
}

variable "target_group_arn" {
  description = "Load balancer target group in which to register IMAP instances."
}

variable "artifact_bucket" {
  description = "S3 bucket where cookbooks are stored."
}

variable "table_arn" {
  description = "DynamoDB table object"
}