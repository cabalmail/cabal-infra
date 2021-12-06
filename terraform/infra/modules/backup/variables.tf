variable "table" {
  type        = string
  description = "ARN of DynamoDB table to back up."
}

variable "efs" {
  type        = string
  description = "ARN of elastic filesystem to back up."
}