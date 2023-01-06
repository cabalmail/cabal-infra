# Trigger cookbook build
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
  "event_type": "trigger_node_build_${var.prod ? "prod" : "stage"}",
  "client_payload": {
    "node_config.js": "${module.admin.node_config}"
  }
}
EO_BODY
}

# Trigger cookbook build
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
  "event_type": "trigger_python_build_${var.prod ? "prod" : "stage"}",
  "client_payload": {
    "bucket_name": "${module.}"
  }
}
EO_BODY
}

# Trigger cookbook build
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
  "event_type": "trigger_react_build_${var.prod ? "prod" : "stage"}",
  "client_payload": {
    "bucket_name": "${module.app.cf_distribution}"
  }
}
EO_BODY
}