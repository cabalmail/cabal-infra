variable "aws_region" {
  type        = string
  description = "AWS region in which to provision primary infrastructure. Default us-west-1."
  default     = "us-west-1"
  validation {
    condition     = can(regex("^[[:alpha:]]{2}-(central|(north|south)?(east|west))-[[:digit:]]$", var.aws_region))
    error_message = "The aws_region does not appear to be a valid AWS region string."
  }
}

variable "repo" {
  type        = string
  description = "This repository. Used for tagging resources."
}

variable "control_domain" {
  type        = string
  description = "The domain for the certificate."
}

variable "prod" {
  type        = bool
  description = "Whether to use the production Let's Encrypt service. Default false."
  default     = false
}

variable "email" {
  type        = string
  description = "Email for the CSR."
}