data "aws_ssm_parameter" "zone" {
  name = "/cabal/control_domain_zone_id"
}

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

variable "image_tag" {
  type        = string
  description = "Docker image tag for the mail container images (git SHA or 'latest')."
  default     = "latest"
}

variable "imap_scale" {
  type = object({
    min  = number
    max  = number
    des  = number
    size = string
  })
  description = "Minimum, maximum, and desired number of IMAP servers; and size of IMAP servers. IMPORTANT: This stack uses open source Dovecot, which does not support multiple instances accessing the same mailstore over NFS. Since this stack also uses NFS for the mailstore, all three of these numbers should always be set to 1. Defaults to { min = 0, max = 0, des = 0, size = \"t2.micro\" } in order to prevent unexpected AWS charges."
  default = {
    min  = 0
    max  = 0
    des  = 0
    size = "t2.micro"
  }
  validation {
    condition = alltrue([
      (floor(var.imap_scale.min) == var.imap_scale.min),
      (floor(var.imap_scale.max) == var.imap_scale.max),
      (floor(var.imap_scale.des) == var.imap_scale.des),
      (var.imap_scale.min >= 0),
      (var.imap_scale.max >= 0),
      (var.imap_scale.des >= 0),
    ])
    error_message = "The imap_scale attributes must be non-negative integers."
  }
  validation {
    condition = alltrue([
      (var.imap_scale.min <= var.imap_scale.des),
      (var.imap_scale.des <= var.imap_scale.max),
    ])
    error_message = "The imap_scale attributes must satisfy the relationship min <= des <= max."
  }
  validation {
    condition = alltrue([
      (var.imap_scale.min <= 1),
      (var.imap_scale.max <= 1),
      (var.imap_scale.des <= 1),
    ])
    error_message = "The imap_scale attributes cannot be greater than 1."
  }
}

variable "smtpin_scale" {
  type = object({
    min  = number
    max  = number
    des  = number
    size = string
  })
  description = "Minimum, maximum, and desired number of incoming SMTP servers; and size of incoming SMTP servers. All three numbers should be at least 1, and must satisfy minimum <= desired <= maximum. Defaults to { min = 0, max = 0, des = 0, size = \"t2.micro\" } in order to prevent unexpected AWS charges."
  default = {
    min  = 0
    max  = 0
    des  = 0
    size = "t2.micro"
  }
  validation {
    condition = alltrue([
      (floor(var.smtpin_scale.min) == var.smtpin_scale.min),
      (floor(var.smtpin_scale.max) == var.smtpin_scale.max),
      (floor(var.smtpin_scale.des) == var.smtpin_scale.des),
      (var.smtpin_scale.min >= 0),
      (var.smtpin_scale.max >= 0),
      (var.smtpin_scale.des >= 0),
    ])
    error_message = "The smtpin_scale attributes must be non-negative integers."
  }
  validation {
    condition = alltrue([
      (var.smtpin_scale.min <= var.smtpin_scale.des),
      (var.smtpin_scale.des <= var.smtpin_scale.max),
    ])
    error_message = "The smtpin_scale attributes must satisfy the relationship min <= des <= max."
  }
}

variable "smtpout_scale" {
  type = object({
    min  = number
    max  = number
    des  = number
    size = string
  })
  description = "Minimum, maximum, and desired number of outgoing SMTP servers; and size of outgoing SMTP servers. All three numbers should be at least 1, and must satisfy minimum <= desired <= maximum. Defaults to { min = 0, max = 0, des = 0, size = \"t2.micro\" } in order to prevent unexpected AWS charges."
  default = {
    min  = 0
    max  = 0
    des  = 0
    size = "t2.micro"
  }
  validation {
    condition = alltrue([
      (floor(var.smtpout_scale.min) == var.smtpout_scale.min),
      (floor(var.smtpout_scale.max) == var.smtpout_scale.max),
      (floor(var.smtpout_scale.des) == var.smtpout_scale.des),
      (var.smtpout_scale.min >= 0),
      (var.smtpout_scale.max >= 0),
      (var.smtpout_scale.des >= 0),
    ])
    error_message = "The smtpout_scale attributes must be non-negative integers."
  }
  validation {
    condition = alltrue([
      (var.smtpout_scale.min <= var.smtpout_scale.des),
      (var.smtpout_scale.des <= var.smtpout_scale.max),
    ])
    error_message = "The smtpout_scale attributes must satisfy the relationship min <= des <= max."
  }
}

variable "backup" {
  type        = bool
  description = "Whether to create backups of critical data. Defaults to the prod setting. Defaults to false."
  default     = false
}

variable "chef_license" {
  type        = string
  description = "Must be the word 'accept' in order to indicate your acceptance of the Chef license. The license text can be viewed here: https://www.chef.io/end-user-license-agreement."
  default     = "not accepted"
  validation {
    condition     = var.chef_license == "accept"
    error_message = "You cannot use this stack without accepting the Chef license. Indicate your acceptance by setting the chef_license variable to 'accept'. The license text can be viewed here: [https://www.chef.io/end-user-license-agreement]."
  }
}