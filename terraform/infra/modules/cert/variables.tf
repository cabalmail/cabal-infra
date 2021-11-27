variable "control_domain" {
  description = "Root domain for infrastructure."
}

variable "zone_id" {
  description = "Route 53 Zone ID for control domain."
}

variable "prod" {
  description = "Whether to use the production certificate API."
}

variable "email" {
  description = "Contact email for the certificate requester for the certificate API."
}