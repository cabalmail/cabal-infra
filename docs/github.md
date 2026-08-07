# Github

You must [sign up for a Github account](https://github.com/signup) if you don't already have one.

After signing up and logging in, [fork this repository](https://docs.github.com/en/get-started/quickstart/fork-a-repo). (Do not try to create infrastucture directly from the original repo.) Note the URL of the repository. You will need it later.

1. Log in to your Github account.
2. Navigate to the newly forked repository.

## Repository secrets

Navigate to **Settings -> Secrets and variables -> Actions -> Secrets** and add the following secret. It applies to all workflows across every environment.

| Secret | Value |
| --- | --- |
| `AWS_REGION` | AWS region, e.g. `us-east-1`. Must match `TF_VAR_AWS_REGION`. |

CI authenticates to AWS with GitHub OIDC, not a static access key, so there are no `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets to set. The role each environment assumes is configured per-environment below (`AWS_DEPLOY_ROLE_ARN`).

## Environment variables and secrets

The remaining configuration is set per-environment under **Settings -> Environments -> [environment name]**. Create two environments per named branch: `prod` (maps to `main`), `gate-prod`, `stage`, `gate-stage`, `development`, and `gate-development`. Optionally add protection rules to the three `gate-*` environments. Potentially destructive jobs in Github workflows are placed behind other jobs that depend on the `gate-*` environments, making them the best place for protection rules. Required reviewers on the gate environments are also what pause the first provisioning run between the dns and infra stages (see [setup](./setup.md)), so add them at least for that run.

### AWS deploy role (OIDC)

CI assumes an IAM role via GitHub OIDC instead of using static keys. Set this as a **variable** (not a secret) on each of `prod`, `stage`, and `development`, pointing at the `cicd` role in that environment's AWS account.

| Variable | Example | Notes |
| --- | --- | --- |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::123456789012:role/cicd` | The role ARN from [AWS setup](./aws.md) step 7 for this environment's account. The deploy workflows assume it via `aws-actions/configure-aws-credentials`. Create the role + provider before the first deploy into that account. |

### Core infrastructure

These are required for every environment.

| Variable | Example | Notes |
| --- | --- | --- |
| `TF_VAR_AVAILABILITY_ZONES` | `[\"us-east-1a\",\"us-east-1b\"]` | List of AZs. Monitoring requires at least two; a single AZ is fine otherwise. Quotes must be escaped with a single backslash. |
| `TF_VAR_AWS_REGION` | `us-east-1` | Must match the `AWS_REGION` repository secret. |
| `TF_VAR_BACKUP` | `true` | Enables AWS Backup for DynamoDB and EFS. |
| `TF_VAR_CIDR_BLOCK` | `10.0.0.0/16` | VPC CIDR block. |
| `TF_VAR_CONTROL_DOMAIN` | `example.net` | Domain for infrastructure endpoints (`admin.`, `imap.`, `smtp-out.`, etc.). |
| `TF_VAR_EMAIL` | `your_email@example.com` | Operator contact address. |
| `TF_VAR_ENVIRONMENT` | `production` | Passed into Terraform as the environment name. |
| `TF_VAR_IMAP_SCALE` | `{ min = 1, max = 1, des = 1, size = \\"t3.small\\" }` | ECS IMAP tier autoscaling parameters. Quotes must be escaped. |
| `TF_VAR_INVITATION_CODE` | `shared-signup-secret` | Optional. When set, signups require this code. Leave unset or empty to keep signups open. |
| `TF_VAR_ENFORCE_ADMIN_MFA` | `false` | Optional. When `true`, the `require_admin_mfa` pre-token-generation trigger refuses sign-in tokens to admin-group members with no enrolled MFA factor. Default `false` (audit mode, log-only). Flip only after every admin has enrolled TOTP. |
| `TF_VAR_ENFORCE_USER_MFA` | `false` | Optional. Same gate for all non-admin users (a dedicated enrollment app client lets locked-out users enroll self-service). Default `false`. Flip only after the user population has enrolled TOTP. |
| `TF_VAR_MAIL_DOMAINS` | `[\\"example.com\\",\\"example.org\\"]` | Mail address namespaces. No apex addressing -- see architecture notes. Quotes must be escaped. |
| `TF_VAR_PROD` | `true` | Enables production-only Terraform resources. Set `true` for `prod`, `false` elsewhere. |
| `TF_VAR_REPO` | `https://github.com/your-account/cabal-infra` | URL of your forked repository. |
| `TF_VAR_SMTPIN_SCALE` | `{ min = 1, max = 1, des = 1, size = \\"t2.micro\\" }` | ECS SMTP-IN tier autoscaling parameters. Quotes must be escaped. |
| `TF_VAR_SMTPOUT_SCALE` | `{ min = 1, max = 1, des = 1, size = \\"t2.micro\\" }` | ECS SMTP-OUT tier autoscaling parameters. Quotes must be escaped. |

Note that quotation marks must be escaped with a single backslash. (If you're reading this document in raw markdown, you'll see double backslashes.)

### Quiesce

`TF_VAR_QUIESCED` controls whether the environment's compute is scaled to zero across Terraform runs. See [quiesce.md](./quiesce.md) for the full workflow.

| Variable | Example | Notes |
| --- | --- | --- |
| `TF_VAR_QUIESCED` | `false` | Set `true` after running `quiesce` with `action: down` to keep the environment scaled down across subsequent Terraform runs. Omit or set `false` for normal operation. |

### State encryption

`STATE_KMS_KEY_ID` opts an environment into SSE-KMS encryption of its Terraform state. It is read by [`make-terraform.sh`](../.github/scripts/make-terraform.sh), not by Terraform, so it has no `TF_VAR_` prefix. Leave it unset for the default SSE-S3 backend. See [Encrypting Terraform state with SSE-KMS](./terraform-state-encryption.md) for the key-creation and activation runbook.

| Variable | Example | Notes |
| --- | --- | --- |
| `STATE_KMS_KEY_ID` | `arn:aws:kms:us-east-1:111122223333:key/abcd-1234` | Optional. Key ARN of the environment's state CMK. When set, state objects are written with SSE-KMS under this key; reading state then also requires `kms:Decrypt`. Unset/empty keeps the default SSE-S3 backend. |

### DNSSEC

`TF_VAR_DNSSEC_ENABLED` opts an environment into DNSSEC signing of every zone Cabalmail manages -- the control-domain zone and each mail-apex zone. It is off by default and opt-in per environment. Enabling, disabling, and KSK rotation each involve a registrar DS-record step whose ordering matters: a DS record published against an unsigned zone is an outage. Read [DNSSEC](./dnssec.md) before touching it, and check the CI deploy policy in [the AWS setup guide](./aws.md) for the KMS and Route 53 grants the first apply needs.

| Variable | Example | Notes |
| --- | --- | --- |
| `TF_VAR_DNSSEC_ENABLED` | `false` | Optional. When `true`, each stack creates a us-east-1 ECC_NIST_P256 KMS key (about $1/month per stack), a per-zone key-signing key, and turns on signing; the DS record each registrar needs is surfaced as a Terraform output. Default `false`. Signing is safe on its own -- the chain of trust forms only when you publish the DS record at the registrar afterwards (sign first, DS second). |

### IMAP connection pooling

`TF_VAR_IMAP_POOL_ENABLED` opts an environment into reuse of authenticated IMAP sessions across warm invocations of the API Lambdas, instead of a fresh login per request. It is off by default and opt-in per environment. See [IMAP connection pooling in the API Lambdas](./operations.md#imap-connection-pooling-in-the-api-lambdas) for what it does, the safety posture, and rollback.

| Variable | Example | Notes |
| --- | --- | --- |
| `TF_VAR_IMAP_POOL_ENABLED` | `false` | Optional. When `true`, the API Lambdas reuse an authenticated master-user IMAP session across warm invocations (keyed by host and user) rather than reconnecting per request. Default `false`; the off path is the original connect/login/logout. Validate in `stage` before promoting to `prod`. |

### Test fixtures

| Variable | Example | Notes |
| --- | --- | --- |
| `TF_VAR_SINKHOLE` | `false` | Optional, non-prod only (a validation block refuses it in prod). When `true`, deploys the [SMTP sinkhole test fixture](./operations.md#test-fixtures-and-pre-promotion-verification) — a tiny configurable SMTP listener used to force deterministic 4xx/5xx responses in test sequences. |

### Monitoring

These variables gate the optional monitoring stack. See [monitoring.md](./monitoring.md) for the full setup guide.

| Variable | Example | Notes |
| --- | --- | --- |
| `TF_VAR_MONITORING` | `true` | Enables the monitoring stack (Uptime Kuma, ntfy, Healthchecks, Prometheus, Alertmanager, Grafana). Requires at least two AZs in `TF_VAR_AVAILABILITY_ZONES`. Set `true` in `prod`; leave `false` or unset elsewhere unless actively testing. |
| `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN` | `false` | Controls whether the Healthchecks signup form accepts new accounts. Default `false`. Flip to `true` for the bootstrap signup in [monitoring.md](./monitoring.md) step 11, then back to `false`. Has no effect when `TF_VAR_MONITORING=false`. |

### SMS -- AWS End User Messaging

| Variable | Example | Notes |
| --- | --- | --- |
| `TF_VAR_TEN_DLC_CAMPAIGN_REGISTRATION_ID` | `registration-0123456789abcdef` | Registration id of this account's approved 10DLC campaign. When set, Terraform provisions a 10DLC phone number against the campaign and the post-apply step converges its HELP/STOP/START keywords. Leave unset until the campaign is approved. See [sms-10dlc.md](./sms-10dlc.md) for the registration runbook. |

## Claude automation tool allowlist

The Claude automation workflow (`.github/workflows/claude.yml`) runs the
Claude Code Action with an explicit `--allowed-tools` allowlist and
`--permission-mode acceptEdits`, not `bypassPermissions`. File edits apply
automatically (there is no human in CI to approve them), but every shell
command is checked against the allowlist and anything outside it fails
closed. Because the prompt embeds untrusted issue and comment text, the
allowlist is a security boundary, not just a convenience: destructive shell
verbs such as `rm` are deliberately absent so a prompt-injection payload
cannot run them even if it slips past the untrusted-input wrapper.

Both jobs -- `on-labeled-issue` and `on-mention` -- carry the same list, and
the Dependabot remediation job (`.github/workflows/dependabot.yml`) carries
its own narrower one.

When a legitimate Claude run needs a tool that is not on the list, the
command is denied and the denial is visible in the run log (the on-mention
job sets `show_full_output: true`, and the labeled-issue job surfaces it in
the transcript). To grant it:

1. Edit the `claude_args` line in **both** `on-labeled-issue` and
   `on-mention` in `claude.yml`, keeping the two lists identical.
2. Add the entry as `Bash(<command>:*)` for a shell command (for example
   `Bash(make:*)`), or as the bare tool name for a built-in
   (`Read`, `Edit`, `Write`, `Glob`, `Grep`).
3. Keep the list single-quoted and on one line so YAML line-folding does not
   insert spaces into it.
4. Do not add destructive primitives (`rm`, `dd`, `mkfs`, `sudo`, raw
   `curl`/`wget` to arbitrary hosts). If a task genuinely needs to remove a
   file, prefer the `Edit`/`Write` tools or a scoped `git` command already
   covered by `Bash(git:*)`.
