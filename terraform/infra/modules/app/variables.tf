data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

variable "layers" {
  type        = map
  description = "List of layer ARNs"
}
variable "user_pool_id" {
  type = string
  description = "ID of the Cognito user pool."
}

variable "user_pool_client_id" {
  type        = string
  description = "Client ID for authenticating with the Cognito user pool."
}

variable "region" {
  type        = string
  description = "The AWS region."
}

variable "control_domain" {
  type        = string
  description = "The control domain."
}

variable "relay_ips" {
  type        = list(string)
  description = "Egress IP addresses."
}

variable "cert_arn" {
  type        = string
  description = "ARN for the AWS Certificate Manager certificate for the control domain."
}

variable "zone_id" {
  type        = string
  description = "Route 53 zone ID for the control domain."
}

variable "domains" {
  type        = list
  description = "List of email domains."
}

variable "repo" {
  type        = string
  description = "Repo tag value for SSM run command target."
}

variable "dev_mode" {
  type        = bool
  description = "If true, forces Cloudfront to non-caching configuration."
}

variable "stage_name" {
  type        = string
  default     = "prod"
  description = "Name for the API Gateway stage. Default: prod."
}

variable "bucket" {
  type        = string
  description = "Name of s3 bucket"
}

variable "bucket_domain_name" {
  type        = string
  description = "Domain name of s3 bucket"
}

variable "origin" {
  type        = string
  description = "S3 Origin ID for CloudFront"
}
