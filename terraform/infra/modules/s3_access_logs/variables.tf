variable "control_domain" {
  type        = string
  description = "Control domain. The three content bucket names that deliver access logs here derive from it (admin.<control_domain>, www.<control_domain>, cache.<control_domain>)."
  validation {
    condition     = can(regex("^(([[:alpha:]]|-|_|[[:digit:]])+\\.)+[[:alpha:]]+$", var.control_domain))
    error_message = "The control_domain does not appear to be a valid domain name."
  }
}
