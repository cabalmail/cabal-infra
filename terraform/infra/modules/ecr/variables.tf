variable "tiers" {
  type        = list(string)
  description = "List of mail service tiers. One ECR repository is created per tier."
  default     = ["imap", "smtp-in", "smtp-out"]
}

variable "extra_repositories" {
  type        = list(string)
  description = "Additional ECR repositories to create that do not need prevent_destroy protection."
  default     = []
}

variable "monitoring_repositories" {
  type        = list(string)
  description = "Monitoring-tier ECR repositories. Created with lifecycle { prevent_destroy = true } so toggling var.monitoring off (or trimming the docker matrix) cannot destroy image history."
  default     = []
}
