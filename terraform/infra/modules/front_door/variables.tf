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

variable "cert_arn" {
  type        = string
  description = "ACM certificate ARN covering www.<control_domain>. The infra cert module issues *.<control_domain>, which covers this site."
}

variable "access_logs_bucket" {
  type        = string
  description = "Name of the shared S3 server-access-log target bucket (modules/s3_access_logs) this site bucket's access logs are delivered to."
}
