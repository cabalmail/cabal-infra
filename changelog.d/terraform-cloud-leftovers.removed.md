- The last Terraform Cloud leftovers: infra.yml, quiesce.yml, and
  destroy_terraform.yml no longer plumb the unused TF_TOKEN secret
  (TF_API_TOKEN env entries and setup-terraform
  cli_config_credentials_token inputs - nothing contacts app.terraform.io
  with the S3 backend); deleted docs/terraform.tfvars.example, the old
  Terraform Cloud workspace-variables example whose github_token and
  legacy EC2 scale variables no longer exist in either stack (variables
  are supplied as GitHub Environment TF_VAR_* vars per docs/github.md);
  and regenerated terraform/dns/README.md with terraform-docs, dropping
  the stale github_token input and TFC-era resources from its tables.
