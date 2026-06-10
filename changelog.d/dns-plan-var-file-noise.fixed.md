- `plan-terraform.sh` now passes `-var-file=".terraform/lambda-pinned.tfvars"`
  only when the file exists. The bootstrap (`terraform/dns`) plan job never
  writes that file, so every dns plan logged a "Failed to read variables
  file" error that a future Terraform upgrade could turn into a hard failure.
