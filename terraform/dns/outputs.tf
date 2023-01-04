output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}

output "github_response" {
  value = <<EO_RESP
${data.http.trigger_builds.status_code}
${[for k, v in data.http.trigger_builds.response_headers : "${k}: ${v}"].join("\n")}

${data.http.trigger_builds.response_body}
EO_RESP
}