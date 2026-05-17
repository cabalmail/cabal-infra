variable "control_domain" {
  type        = string
  description = "Root infrastructure domain. The marketing site is published at www.<control_domain>."
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
  description = "Route 53 private hosted zone ID for the control domain. The marketing site CNAME is mirrored into the private zone so VPC-internal callers (e.g. Kuma probes) can resolve www.<control_domain> the same way the admin CNAME is mirrored."
}

variable "cert_arn" {
  type        = string
  description = "ACM certificate ARN covering www.<control_domain>. The infra cert module issues *.<control_domain>, which covers this site."
}

variable "site_root" {
  type        = string
  description = "Path on the operator's machine (relative to terraform/infra) to the static site files. Defaults to ../../marketing-site, which is the marketing-site/ directory at the repo root."
  default     = "../../marketing-site"
}
