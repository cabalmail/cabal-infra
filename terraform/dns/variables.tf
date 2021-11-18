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
  description = "This repository. Used for resource tagging."
  default     = "https://github.com/ccarr-cabal/cabal-dns/tree/main"
}

variable "control_domain" {
  type        = string
  description = "The domain used for naming your email infrastructure. E.g., if you want to host imap.example.com and smtp-relay-west.example.com, then this would be 'example.com'."
}