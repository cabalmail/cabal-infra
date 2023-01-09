# Trigger nodejs API build
# Data source is ignored, but triggers Github actions as a side-effect
data "http" "trigger_node_builds" {
  url          = "https://api.github.com/repos/cabalmail/cabal-infra/dispatches"
  method       = "POST"
  request_headers = {
    Accept               = "application/vnd.github+json"
    Authorization        = "Bearer ${var.github_token}"
    X-GitHub-Api-Version = "2022-11-28"
  }
  request_body = <<EO_BODY
{
  "event_type": "trigger_api_node_build_${var.dev_mode ? "stage" : "prod"}",
  "client_payload": {
    "node_config.js": "${aws_s3_object.node_config.key}"
  }
}
EO_BODY
}

# Trigger python API build
# Data source is ignored, but triggers Github actions as a side-effect
data "http" "trigger_python_builds" {
  url          = "https://api.github.com/repos/cabalmail/cabal-infra/dispatches"
  method       = "POST"
  request_headers = {
    Accept               = "application/vnd.github+json"
    Authorization        = "Bearer ${var.github_token}"
    X-GitHub-Api-Version = "2022-11-28"
  }
  request_body = <<EO_BODY
{
  "event_type": "trigger_api_python_build_${var.dev_mode ? "stage" : "prod"}",
  "client_payload": {}
}
EO_BODY
}

# Trigger build and deploy of React Application
# Data source is ignored, but triggers Github actions as a side-effect
data "http" "trigger_react_build" {
  url          = "https://api.github.com/repos/cabalmail/cabal-infra/dispatches"
  method       = "POST"
  request_headers = {
    Accept               = "application/vnd.github+json"
    Authorization        = "Bearer ${var.github_token}"
    X-GitHub-Api-Version = "2022-11-28"
  }
  request_body = <<EO_BODY
{
  "event_type": "trigger_react_build_${var.dev_mode ? "stage" : "prod"}",
  "client_payload": {
    "cf_distribution": "${aws_ssm_parameter.cf_distribution.name}"
  }
}
EO_BODY
}