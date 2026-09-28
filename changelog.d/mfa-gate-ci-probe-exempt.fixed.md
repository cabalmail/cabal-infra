- **Post-deploy mail probe blocked at sign-in by the MFA gate.** The `ci-probe`
  service account was missing from `EXEMPT_USERS` on the pre-token-generation
  trigger, so it authenticated normally for its 48-hour grace window and was
  refused from then on -- every `mail-probe` job on stage and prod died at
  Cognito sign-in without exercising the mail path at all. The account is now
  exempted alongside `master` and `dmarc`, and a source scan pins every
  Terraform-declared Cognito user to that list so a new service account cannot
  repeat it.
