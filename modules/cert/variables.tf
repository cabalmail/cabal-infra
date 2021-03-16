variable "repo" {
  type        = string
  description = "This repository. Used for tagging resources."
}

variable "domain" {
  type        = string
  description = "The domain for the certificate."
}

variable "sans" {
  type        = list(string)
  description = "List of Subject Alternative Names"
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