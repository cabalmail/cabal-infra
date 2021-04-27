variable "aws_primary_region" {
  type        = string
  description = "AWS region in which to provision primary infrastructure. Default us-west-1."
  default     = "us-west-1"
  validation {
    condition     = can(regex("^\w{2}-(central|(north|south)?(east|west))-\d", var.aws_primary_region))
    error_message = "aws_primary_region does not appear to be a valid AWS region string."
  }
}

variable "aws_secondary_region" {
  type        = string
  description = "AWS region in which to provision secondary infrastructure. Default us-east-1."
  default     = "us-east-1"
  validation {
    condition     = can(regex("^\w{2}-(central|(north|south)?(east|west))-\d", var.aws_secondary_region))
    error_message = "aws_secondary_region does not appear to be a valid AWS region string."
  }
}

variable "primary_availability_zones" {
  type        = list(string)
  description = "List of availability zones to use for the primary region."
  default     = [
    "us-west-1a"
  ]
}

variable "secondary_availability_zones" {
  type        = list(string)
  description = "List of availability zones to use for the secondary region."
  default     = [
    "us-east-1a"
  ]
}

variable "create_secondary" {
  type        = bool
  description = "Whether to create infrastructure in a second region. Recommended for prod. Default false."
  default     = false
}

variable "primary_cidr_block" {
  type        = string
  description = "CIDR block for the VPC in the primary region."
}

variable "secondary_cidr_block" {
  type        = string
  description = "CIDR block for the VPC in the secondary region."
}

variable "az_count" {
  type        = number
  description = "Number of Availability Zones to use. 3 recommended for prod. Default 1."
  default     = 1
}

variable "repo" {
  type        = string
  description = "This repository. Used for resource tagging."
  default     = "https://github.com/ccarr-cabal/cabal-infra/tree/main"
}

variable "chef_organization_url" {
  type        = string
  description = "URL for your chef organization. E.g. https://api.chef.io/organizations/cabal-example"
}

variable "chef_client" {
  type        = string
  description = "User for making API calls to Chef Server."
}

variable "chef_client_key" {
  type        = string
  description = "RSA private key for making API calls to Chef Server."
}

variable "prod_cert" {
  type        = bool
  description = "Whether to use the production Let's Encrypt API. Default false."
  default     = false
}

variable "cert_email" {
  type        = string
  description = "Email address to use in certificate signing requests. If your CabalMail system is not yet opperational, you should specify an address where you can receive mail elsewhere. Once CabalMail is running, you can safely change this value."
}

variable "control_domain" {
  type        = string
  description = "The domain used for naming your email infrastructure. E.g., if you want to host imap.example.com and smtp-relay-west.example.com, then this would be 'example.com'."
}

variable "mail_domains" {
  type        = list(string)
  description = "List of domains from which you want to send mail, and to which you want to allow mail to be sent. Must have at least one."
}