- **Terraform provider versions locked and Dependabot-managed.** The
  `terraform/infra` stack now commits its `.terraform.lock.hcl`, so CI
  installs exactly the locked provider builds instead of whatever
  release satisfied the constraint at plan time, and a new `terraform`
  entry in `dependabot.yml` opens the bump PRs for both stacks, each of
  which runs the stack's plan and gated apply on merge.
