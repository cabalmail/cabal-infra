variable "control_domain" {
  type        = string
  description = "Root domain for infrastructure."
}

variable "zone_id" {
  type        = string
  description = "Route 53 Zone ID for control domain."
}
