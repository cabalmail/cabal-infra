variable "private_subnets" {
  description = "Subnets for imap ec2 instances."
}

variable "repo" {
  description = "This repository. Used for tagging resources."
}

variable "target_group_arn" {
  description = "Load balancer target group in which to register IMAP instances."
}