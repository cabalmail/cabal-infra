variable "control_domain" {
  type        = string
  description = "Root domain for infrastructure. CAA authorizing ACM and Let's Encrypt is published at its apex."
}

variable "control_domain_zone_id" {
  type        = string
  description = "Route 53 Zone ID for the control domain (owned by the bootstrap terraform/dns stack)."
}

variable "mail_domains" {
  type = list(object({
    domain  = string
    zone_id = string
  }))
  description = "Mail domains and their Route 53 zone IDs (module.domains.domains). Each gets an ACM-only CAA record; the control domain is skipped here as it is covered by control_domain_zone_id."
}

variable "iodef_email" {
  type        = string
  description = "Contact address for the CAA iodef property, where a CA reports requests that violate the policy. The root stack sets this to the Let's Encrypt contact email (var.email)."
}

variable "ttl" {
  type        = number
  default     = 3600
  description = "TTL in seconds for the CAA records."
}
