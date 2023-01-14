output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}

output "http_sample" {
  value = data.http.trigger_builds["cookbook_deploy"].response_body
}