variable "control_domain" {
  type        = string
  description = "Root infrastructure domain. The front door site is published at www.<control_domain>."
  validation {
    condition     = can(regex("^(([[:alpha:]]|-|_|[[:digit:]])+\\.)+[[:alpha:]]+$", var.control_domain))
    error_message = "The control_domain does not appear to be a valid domain name."
  }
}

variable "zone_id" {
  type        = string
  description = "Route 53 public hosted zone ID for the control domain."
}

variable "private_zone_id" {
  type        = string
  description = "Route 53 private hosted zone ID for the control domain. The front door site CNAME is mirrored into the private zone so VPC-internal callers (e.g. Kuma probes) can resolve www.<control_domain> the same way the admin CNAME is mirrored."
}

variable "cert_arn" {
  type        = string
  description = "ACM certificate ARN covering www.<control_domain>. The infra cert module issues *.<control_domain>, which covers this site."
}
