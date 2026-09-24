- **Post-deploy mail probe.** After `app.yml` rolls a core mail tier or
  deploys the API Lambdas, a new `mail-probe` job signs in as a dedicated
  `ci-probe` Cognito user, sends it one message through `/send` and one
  straight at the public MX on port 25, and fails the run unless both
  reach its INBOX carrying smtp-out's `DKIM-Signature` and smtp-in's
  `Authentication-Results` respectively. The rollout wait only proved the
  new container was healthy; this proves the mail path behind it,
  including smtp-in, which same-environment sends never touch. Terraform
  provisions the user, its `ci-probe@mail-admin.<domain>` address and the
  SSM password the deploy role reads. See `docs/mail-probe.md`.
