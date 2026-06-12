output "IMPORTANT" {
  value = [
    "You must get permission from AWS to relay mail through the below IP addresses. See the section on Port 25 in docs/setup.md.",
    "You must update your domain registrations with the name servers from the below domains. See the section on Nameservers in docs/setup.md"
  ]
  description = "Instructions for post-automation steps."
}

output "relay_ips" {
  value = {
    addresses = module.vpc.relay_ips
    domain    = "smtp.${var.control_domain}"
  }
  description = "IP addresses that will be used for outbound mail."
}

output "domains" {
  value       = module.domains.domains
  description = "Nameservers to be added to your domain registrations."
}

output "mail_domain_ds_records" {
  value       = module.domains.ds_records
  description = "Per-apex DNSSEC DS record values to publish at each domain registrar once signing is verified (sign first, DS second - see docs/dnssec.md). Empty until var.dnssec_enabled is true."
}

output "sms_phone_number" {
  value       = module.pool.sms_phone_number
  description = "AWS End User Messaging toll-free phone number for SMS verification. Empty when var.use_eum_sms is false."
}

output "alert_sink_function_url" {
  value       = module.monitoring[*].alert_sink_function_url
  description = "Webhook URL for monitoring. Add to Kuma."
}

output "front_door_url" {
  value       = module.front_door.site_url
  description = "Public URL of the front door site at www.<control_domain>."
}

output "front_door_cf_id" {
  value       = module.front_door.cloudfront_distribution_id
  description = "CloudFront distribution ID for the front door site. Use with aws cloudfront create-invalidation when content is updated."
}
