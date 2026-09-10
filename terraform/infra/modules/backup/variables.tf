variable "table" {
  type        = string
  description = "ARN of DynamoDB table to back up."
}

variable "efs" {
  type        = string
  description = "ARN of elastic filesystem to back up."
}
variable "extra_tables" {
  type        = list(string)
  default     = []
  description = "ARNs of additional DynamoDB tables to include in the backup selection (the RSS reader tables)."
}
