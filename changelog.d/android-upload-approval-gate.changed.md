- **Approval gate before the Play Console upload.** `android.yml` now
  pauses at the same `gate-prod`/`gate-stage` environments as the
  Terraform, app-deploy, and TestFlight workflows before building and
  publishing the signed bundle, so required reviewers on those
  environments make the upload a deliberate act.
