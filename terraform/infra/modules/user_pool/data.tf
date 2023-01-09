# Trigger nodejs counter build
# Data source is ignored, but triggers Github actions as a side-effect
data "http" "trigger_counter_builds" {
  url          = "https://api.github.com/repos/cabalmail/cabal-infra/dispatches"
  method       = "POST"
  request_headers = {
    Accept               = "application/vnd.github+json"
    Authorization        = "Bearer ${var.github_token}"
    X-GitHub-Api-Version = "2022-11-28"
  }
  request_body = <<EO_BODY
{
  "event_type": "trigger_counter_node_build_${var.dev_mode ? "stage" : "prod"}",
  "client_payload": {}
}
EO_BODY
}