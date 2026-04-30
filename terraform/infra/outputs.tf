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

output "sms_phone_number" {
  value       = module.pool.sms_phone_number
  description = "Toll-free phone number used for SMS verification."
}

output "alert_sink_function_url" {
  value       = module.monitoring[*].alert_sink_function_url
  description = "Webhook URL for monitoring. Add to Kuma."
}
