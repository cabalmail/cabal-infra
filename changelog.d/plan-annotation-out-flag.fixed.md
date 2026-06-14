- Restore the Terraform plan delta in the infra.yml plan annotation. It
  had regressed to a "could not render the saved plan file" placeholder
  because the `terraform plan` invocation lost its `-out` flag, so the
  follow-up `terraform show` had no saved plan to render. The plan is
  saved again, and when the delta is too long for a GitHub annotation it
  is now truncated from the front so the `Plan: N to add...` summary line
  always survives.
