variable "mail_domains" {
  type        = list(string)
  description = "List of mail domains."
}

variable "control_domain" {
  type        = string
  description = "The control domain. When it also appears in mail_domains, its pre-existing bootstrap zone is reused instead of creating a duplicate hosted zone for the same name."
}

variable "control_domain_zone_id" {
  type        = string
  description = "Route 53 zone id of the bootstrap control-domain zone (from the dns stack). Used to reference the control zone when the control domain doubles as a mail domain."
}

variable "dnssec_enabled" {
  type        = bool
  description = "Whether to create per-zone KSKs and enable DNSSEC signing on the mail-domain zones. Enabling signing is safe on its own; the chain of trust only forms when the operator publishes each zone's DS record at its registrar afterwards (sign first, DS second - see docs/dnssec.md). Default false."
  default     = false
}
