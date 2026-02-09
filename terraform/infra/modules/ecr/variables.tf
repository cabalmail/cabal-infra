variable "tiers" {
  type        = list(string)
  description = "List of mail service tiers. One ECR repository is created per tier."
  default     = ["imap", "smtp-in", "smtp-out"]
}
