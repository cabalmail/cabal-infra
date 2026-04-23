variable "tiers" {
  type        = list(string)
  description = "List of mail service tiers. One ECR repository is created per tier."
  default     = ["imap", "smtp-in", "smtp-out"]
}

variable "extra_repositories" {
  type        = list(string)
  description = "Additional ECR repositories to create (e.g. uptime-kuma when monitoring is enabled)."
  default     = []
}
