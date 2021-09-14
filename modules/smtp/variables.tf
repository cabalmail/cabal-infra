variable "private_subnets" {
  description = "Subnets for imap ec2 instances."
}

variable "vpc" {
  description = "VPC for the load balancer."
}

variable "type" {
  description = "Type of SMTP server ('in' for inbound, 'out' for outbound)."
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

variable "efs_dns" {
  description = "DNS of Elastic File System"
}