output "IMPORTANT" {
  value = [
    "You must get permission from AWS to relay mail through the below IP addresses. See the section on Port 25 in docs/setup.md.",
    "You must update your domain registrations with the name servers from the below domains. See the section on Nameservers in docs/setup.md"
  ]
}

output "relay_ips" {
  value       = {
    addresses = module.vpc.relay_ips
    domain    = "smtp.${var.control_domain}"
  }
  description = "IP addresses that will be used for outbound mail. See README.md section on PTR records for important instructions."
}

output "domains" {
  value = module.domains.domains
}