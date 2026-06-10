- Surface the Terraform plan delta as a notice annotation on the
  infra.yml run summary page so the pending change set can be reviewed
  before approving the apply gate, and annotate the stack's Terraform
  outputs after a successful apply. The plan annotation is rendered
  from the saved plan file with `terraform show`, so it carries only
  the change set, not the state-refresh log noise.
