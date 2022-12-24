variable "bucket" {
  type        = string
  description = "S3 bucket for artifacts"
}

variable "layers" {
  type        = list(string)
  description = "List of lambda layers indext by runtime 'python' or 'nodejs'"
}