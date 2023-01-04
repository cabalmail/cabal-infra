output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}

output "github_response" {
  value = <<EO_RESP
${resource.http.trigger_builds.status_code}
${resource.http.trigger_builds.response_headers}

${resource.http.trigger_builds.response_body}
EO_RESP
}