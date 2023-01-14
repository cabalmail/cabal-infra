output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}

output "request_url" {
  value = "${local.base_url}/cookbook_deploy_${var.prod ? "prod" : "stage"}/dispatches"
}

output "http_status" {
  value = data.http.trigger_builds["cookbook_deploy"].status_code
}

output "http_body" {
  value = data.http.trigger_builds["cookbook_deploy"].response_body
}