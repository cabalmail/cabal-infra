variable "control_domain" {
  type        = string
  description = "Root domain for infrastructure."
}

variable "zone_id" {
  type        = string
  description = "Route 53 Zone ID for control domain."
}

variable "prod" {
  type        = bool
  description = "Whether to use the production certificate API."
}

variable "email" {
  type        = string
  description = "Contact email for the certificate requester for the certificate API."
}