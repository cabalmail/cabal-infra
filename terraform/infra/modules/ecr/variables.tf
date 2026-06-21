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

variable "allowed_pull_principal_arns" {
  type        = map(list(string))
  description = "Per-repository map of IAM role ARNs permitted to pull. Keyed by repo short name (e.g. \"imap\", \"prometheus\", \"sinkhole\"). Each repo's policy denies the pull actions (ecr:GetDownloadUrlForLayer, ecr:BatchGetImage, ecr:BatchCheckLayerAvailability) to every principal whose ARN is not in that repo's list, so the lists must name every legitimate puller (the task execution role, the shared container-instance role, and the CI/CD deploy role). A repo absent from the map gets no restriction policy. ecr:GetAuthorizationToken is registry-level, not a repository action, and is intentionally not gated here."
}
