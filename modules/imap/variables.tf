variable "private_subnets" {
  description = "Subnets for imap ec2 instances."
}

variable "vpc" {
  description = "VPC for the load balancer."
}

variable "repo" {
  description = "This repository. Used for tagging resources."
}

variable "control_domain" {
  description = "Control domain"
}

variable "target_group_arn" {
  description = "Load balancer target group in which to register IMAP instances."
}

variable "artifact_bucket" {
  description = "S3 bucket where cookbooks are stored."
}

variable "table_arn" {
  description = "DynamoDB table arn"
}

variable "s3_arn" {
  description = "S3 bucket arn"
}