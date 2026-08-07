- **Terraform configuration validation check.**
  `.github/scripts/terraform-validate.sh` runs `terraform init -backend=false`
  and `terraform validate` over a stack, catching the cross-file configuration
  errors the scanners cannot see because they never initialise Terraform — a
  module argument with no matching variable, a reference to an output the
  module does not declare, a wrong type. It needs no credentials and no
  backend.
