locals {
  builds = [
    "cookbook_deploy",
    "lambda_api_node_build",
    "lambda_api_python_build",
    "lambda_counter_node_build",
    "react_deploy"
  ]
  base_url = "https://api.github.com/repos/cabalmail/cabal-infra/actions/workflows"
}
