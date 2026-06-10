- Rewrote docs/terraform.md, which still walked through creating Terraform
  Cloud workspaces, to describe the actual setup: the S3 state bucket
  (including the cross-account bucket policy needed when an environment's
  account does not own the bucket) and how the infra.yml workflow drives
  scan, plan, approval, and apply, including the dns bootstrap gating.
  Updated the provisioning steps in docs/setup.md to match the
  workflow-driven flow, and dropped the stale Terraform Cloud API token
  and personal access token instructions from docs/github.md.
