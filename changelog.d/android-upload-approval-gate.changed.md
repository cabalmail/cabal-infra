- **Approval gate before the Play Console upload.** `android.yml` now
  runs its upload behind the same `gate-prod`/`gate-stage` environments
  as the Terraform, app-deploy, and TestFlight workflows, so a prod
  upload waits for the gate environment's required reviewers; a gate
  environment with no protection rules (currently `gate-stage`) passes
  on its own.
