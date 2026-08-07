- **Terraform configuration validation check.**
  `.github/scripts/terraform-validate.sh` runs `terraform init -backend=false`
  and `terraform validate` over a stack, catching the cross-file configuration
  errors the scanners cannot see because they never initialise Terraform — a
  module argument with no matching variable, a reference to an output the
  module does not declare, a wrong type. The pull-request lint workflow runs it
  over both stacks whenever a Terraform path changes. It needs no credentials
  and no backend.
