data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]
  name_regex  = "^amzn2-ami-hvm-2.0.20\\d{6}.\\d-x86_64-gp2$"
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_default_tags" "current" {}

data "aws_caller_identity" "current" {}

data "aws_iam_policy" "ssm" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

variable "private_subnets" {
  type        = list
  description = "Subnets for imap ec2 instances."
}

variable "vpc" {
  type        = object
  description = "VPC for the load balancer."
}

variable "type" {
  type        = string
  description = "Type of server, 'imap', 'smtp-in', or 'smtp-out."
}

variable "control_domain" {
  type        = string
  description = "Control domain"
}

variable "target_groups" {
  type        = list
  description = "List of load balancer target groups in which to register IMAP instances."
}

variable "artifact_bucket" {
  type        = string
  description = "S3 bucket where cookbooks are stored."
}

variable "table_arn" {
  type        = string
  description = "DynamoDB table arn"
}

variable "s3_arn" {
  type        = string
  description = "S3 bucket arn"
}

variable "efs_dns" {
  type        = string
  description = "DNS of Elastic File System"
}

variable "user_pool_arn" {
  type        = string
  description = "ARN of the Cognito User Pool"
}

variable "user_pool_id" {
  type        = string
  description = "ID of the Cognito User Pool"
}

variable "region" {
  type        = string
  description = "AWS region"
}

variable "client_id" {
  type        = string
  description = "App client ID for Cognito User Pool"
}

variable "ports" {
  type        = list(number)
  description = "Ports to open in security group"
}

variable "private_ports" {
  type        = list(number)
  description = "Ports to open for local traffic in security group"
}

variable "scale" {
  type        = object
  description = "Min, max, and desired settings for autoscale group"
}

variable "chef_license" {
  type        = string
  description = "Must be the string 'accept' in order to install and use Chef Infra Client"
}

variable "private_zone" {
  type        = object
  description = "Zone for internal lookups"
}

variable "cidr_block" {
  type        = string
  description = "Local CIDR range"
}