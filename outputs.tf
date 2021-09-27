output "IMPORTANT" {
  value = "You must get permission from AWS to relay mail through the below IP addresses. See the section on PTR records in README.md."
}

output "relay_ips" {
  value       = module.cabal_vpc.relay_ips
  description = "IP addresses that will be used for outbound mail. See README.md section on PTR records for important instructions."
}

output "user_pool_id" {
  value = module.cabal_pool.user_pool_id
}

output "user_pool_client_id" {
  value = module.cabal_pool.user_pool_client_id
}