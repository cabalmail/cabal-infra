output "relay_ips" {
  value       = cabal_vpc.relay_ips
  description = "IP addresses that will be used for outbound mail. See README.md section on PTR records for important instructions."
}

output "user_pool_id" {
  value = cabal_pool.user_pool_id
}

output "user_pool_client_id" {
  value = cabal_pool.user_pool_client_id
}