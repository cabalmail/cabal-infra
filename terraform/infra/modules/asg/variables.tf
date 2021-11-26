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

data "aws_iam_policy" "ssm" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

variable "private_subnets" {
  description = "Subnets for imap ec2 instances."
}

variable "vpc" {
  description = "VPC for the load balancer."
}

variable "type" {
  description = "Type of server, 'imap', 'smtp-in', or 'smtp-out."
}

variable "control_domain" {
  description = "Control domain"
}

variable "target_groups" {
  description = "List of load balancer target groups in which to register IMAP instances."
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

variable "user_pool_arn" {
  description = "ARN of the Cognito User Pool"
}

variable "user_pool_id" {
  description = "ID of the Cognito User Pool"
}

variable "region" {
  description = "AWS region"
}

variable "client_id" {
  description = "App client ID for Cognito User Pool"
}

variable "ports" {
  description = "Ports to open in security group"
}

variable "private_ports" {
  description = "Ports to open for local traffic in security group"
}

variable "scale" {
  description = "Min, max, and desired settings for autoscale group"
}

variable "chef_license" {
  description = "Must be the string 'accept' in order to install and use Chef Infra Client"
}

variable "private_zone" {
  description = "Zone for internal lookups"
}

variable "cidr_block" {
  description = "Local CIDR range"
}