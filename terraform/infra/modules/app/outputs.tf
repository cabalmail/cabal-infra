output "master_password" {
  value = random_password.password.result
}

output "ssm_document_arn" {
  value = aws_ssm_document.run_chef_now.arn
}

output "trigger" {
  value = "${data.http.trigger_node_builds.response_body}lambda${data.http.trigger_python_builds.response_body}"
}