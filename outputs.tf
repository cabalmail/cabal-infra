output "IMPORTANT" {
  value = [
    "You must get permission from AWS to relay mail through the below IP addresses. See the section on PTR records in README.md.",
    "You must update your domain registrations with the name servers from the below domains. See the section on Name Servers in README.md"
  ]
}

output "relay_ips" {
  value       = module.cabal_vpc.relay_ips
  description = "IP addresses that will be used for outbound mail. See README.md section on PTR records for important instructions."
}

output "domains" {
  value = local.domains
}