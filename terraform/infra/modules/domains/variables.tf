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
