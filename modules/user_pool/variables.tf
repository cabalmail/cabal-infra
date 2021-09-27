variable "control_domain" {
  type        = string
  description = "Base for auth domain. E.g., if control_domain is example.com, then the autho domain will be auth.example.com."
}

variable "zone_id" {
  type        = string
  description = "Zone ID for creating DNS records for auth domain."
}