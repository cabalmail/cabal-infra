variable "environment" {
  type        = string
  description = "A name for your environment such as 'production' or 'staging'."
}

variable "aws_region" {
  type        = string
  description = "AWS region in which to provision primary infrastructure. Default us-west-1."
  default     = "us-west-1"
  validation {
    condition     = can(regex("^[[:alpha:]]{2}-(central|(north|south)?(east|west))-[[:digit:]]$", var.aws_region))
    error_message = "The aws_region does not appear to be a valid AWS region string."
  }
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

variable "availability_zones" {
  type        = list(string)
  description = "List of availability zones to use for the primary region."
  default = [
    "us-west-1a"
  ]
  validation {
    condition = alltrue([
      for str in var.availability_zones : can(regex("^[[:alpha:]]{2}-(central|(north|south)?(east|west))-[[:digit:]][[:alpha:]]$", str))
    ])
    error_message = "One or more of the availability_zones do not appear to be valid AWS availability strings."
  }
}

variable "cidr_block" {
  type        = string
  description = "CIDR block for the VPC in the primary region."
  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "The cidr_block does not appear to be a valid CIDR."
  }
}

variable "repo" {
  type        = string
  description = "This repository. Used for resource tagging."
  default     = "https://github.com/ccarr-cabal/cabal-infra/tree/main"
}

variable "control_domain" {
  type        = string
  description = "The domain used for naming your email infrastructure. E.g., if you want to host imap.example.com and smtp-out.example.com, then this would be 'example.com'. This domain is not used for email addresses."
  validation {
    condition     = can(regex("^(([[:alpha:]]|-|_|[[:digit:]])+\\.)+[[:alpha:]]+$", var.control_domain))
    error_message = "The control_domain does not appear to be a valid domain name."
  }
}

variable "mail_domains" {
  type        = list(string)
  description = "List of domains from which you want to send mail, and to which you want to allow mail to be sent. Must have at least one."
  validation {
    condition = alltrue([
      for str in var.mail_domains : can(regex("^(([[:alpha:]]|-|_|[[:digit:]])+\\.)+[[:alpha:]]+$", str))
    ])
    error_message = "One or more of the mail_domains does not appear to be a valid domain name."
  }
  validation {
    condition     = length(var.mail_domains) > 0
    error_message = "You must have at least one mail_domain."
  }
}

variable "backup" {
  type        = bool
  description = "Whether to create backups of critical data. Defaults to the prod setting. Defaults to false."
  default     = false
}

variable "monitoring" {
  type        = bool
  description = "Whether to deploy the monitoring & alerting stack (Uptime Kuma, self-hosted ntfy, alert_sink Lambda). Defaults to false."
  default     = false
}

variable "healthchecks_registration_open" {
  type        = bool
  description = "Whether the Healthchecks signup form is open. Set to true at bootstrap so the operator can sign up the first user via the magic-link flow, then flip back to false. Has no effect when var.monitoring is false (no Healthchecks task is deployed)."
  default     = false
}


