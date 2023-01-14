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

curl \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer <YOUR-TOKEN>"\
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/OWNER/REPO/actions/workflows/WORKFLOW_ID/dispatches \
  -d '{"ref":"topic-branch","inputs":{"name":"Mona the Octocat","home":"San Francisco, CA"}}'