locals {
  builds = [
    "cookbook_deploy",
    "lambda_api_node",
    "lambda_api_python",
    "lambda_counter_node",
    "react_deploy"
  ]
  base_url = "https://api.github.com/repos/cabalmail/cabal-infra/actions/workflows"
}
