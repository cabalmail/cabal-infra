# Github

You must [sign up for a Github account](https://github.com/signup) if you don't already have one.

After signing up and logging in, [fork this repository](https://docs.github.com/en/get-started/quickstart/fork-a-repo). (Do not try to create infrastucture directly from the original repo.) Note the URL of the repository. You will need it later.

1. Log in to your Github account.
2. Navigate to the newly forked repository.

## Repository secrets

Navigate to **Settings -> Secrets and variables -> Actions -> Secrets** and add the following secrets. These apply to all workflows across every environment.

| Secret | Value |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | Access key ID from [AWS setup](./aws.md) step 10. |
| `AWS_SECRET_ACCESS_KEY` | Access key secret from [AWS setup](./aws.md) step 10. |
| `AWS_REGION` | AWS region, e.g. `us-east-1`. Must match `TF_VAR_AWS_REGION`. |

## Environment variables and secrets

The remaining configuration is set per-environment under **Settings -> Environments -> [environment name]**. Create two environments per named branch: `prod` (maps to `main`), `gate-prod`, `stage`, `gate-stage`, `development`, and `gate-development`. Optionally add protection rules to the three `gate-*` environments. Potentially destructive jobs in Github workflows are placed behind other jobs that depend on the `gate-*` environments, making them the best place for protection rules. Required reviewers on the gate environments are also what pause the first provisioning run between the dns and infra stages (see [setup](./setup.md)), so add them at least for that run.

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

### Monitoring

These variables gate the optional monitoring stack. See [monitoring.md](./monitoring.md) for the full setup guide.

| Variable | Example | Notes |
| --- | --- | --- |
| `TF_VAR_MONITORING` | `true` | Enables the monitoring stack (Uptime Kuma, ntfy, Healthchecks, Prometheus, Alertmanager, Grafana). Requires at least two AZs in `TF_VAR_AVAILABILITY_ZONES`. Set `true` in `prod`; leave `false` or unset elsewhere unless actively testing. |
| `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN` | `false` | Controls whether the Healthchecks signup form accepts new accounts. Default `false`. Flip to `true` for the bootstrap signup in [monitoring.md](./monitoring.md) step 11, then back to `false`. Has no effect when `TF_VAR_MONITORING=false`. |

### SMS -- AWS End User Messaging

| Variable | Example | Notes |
| --- | --- | --- |
| `TF_VAR_USE_EUM_SMS` | `false` | Provisions an AWS End User Messaging toll-free number for Cognito SMS via SNS. Default `false`. |

### TFV registration

These are used by the `register-tfv` workflow to submit a toll-free verification (TFV) registration to AWS End User Messaging. Only needed when `TF_VAR_USE_EUM_SMS=true`. See [sms-tfv-setup.md](./sms-tfv-setup.md) for the full runbook, including the IAM policy you must attach before the first run.

**Variables** (non-sensitive; visible in workflow logs):

| Variable | Example | Notes |
| --- | --- | --- |
| `TFV_COMPANY_NAME` | `Example Holdings LLC` | Legal entity name exactly as registered. Must match your EIN documentation. |
| `TFV_COMPANY_WEBSITE` | `https://www.cabal-mail.net` | Live HTTPS URL for the front-door site. Must describe the service. |
| `TFV_COMPANY_ADDRESS1` | `1234 Example Street` | Street address line 1. |
| `TFV_COMPANY_ADDRESS2` | `Suite 200` | Optional; omit the variable if not applicable. |
| `TFV_COMPANY_CITY` | `Wilmington` | |
| `TFV_COMPANY_STATE` | `DE` | Two-letter US state code or two/three-letter province code. |
| `TFV_COMPANY_ZIP` | `19801` | |
| `TFV_COMPANY_COUNTRY` | `US` | ISO 3166-1 alpha-2. Defaults to `US` if unset. |
| `TFV_CONTACT_FIRST_NAME` | `Jane` | Support contact first name. |
| `TFV_CONTACT_LAST_NAME` | `Doe` | Support contact last name. |
| `TFV_MONTHLY_VOLUME` | `10` | Optional. Choices: `10`, `100`, `1,000`, `10,000`, `100,000`, `250,000`, `500,000`, `750,000`, `1,000,000`, `5,000,000`, `10,000,000+`. Default `10` is right for a hobby or small instance. |
| `TFV_USE_CASE_CATEGORY` | `ONE_TIME_PASSCODES` | Optional. Default `ONE_TIME_PASSCODES`. Must be one of the SCREAMING_SNAKE_CASE enum values AWS accepts; the workflow logs the authoritative list at startup. |
| `TFV_BUSINESS_TYPE` | `PRIVATE_PROFIT` | Optional. Allowed: `PRIVATE_PROFIT`, `PUBLIC_PROFIT`, `NON_PROFIT`, `SOLE_PROPRIETOR`, `GOVERNMENT`. Default `PRIVATE_PROFIT`. |
| `TFV_OPT_IN_TYPE` | `DIGITAL_FORM` | Optional. Allowed: `VERBAL`, `DIGITAL_FORM`, `PAPER_FORM`, `TEXT`, `QR_CODE`. Default `DIGITAL_FORM` matches the React signup form. |
| `TFV_TAX_ID_AUTHORITY` | `EIN` | Optional. Only used when `TFV_TAX_ID` is set. Allowed: `EIN`, `CBN`, `CRN`, `PROVINCIAL_NUMBER`, `VAT`, `ACN`, `ABN`, `BRN`, `SIREN`, `SIRET`, `NZBN`, `USt-IdNr`, `CIF`, `NIF`, `CNPJ`, `UID`, `NEQ`, `OTHER`. Default `EIN`. |
| `TFV_TAX_ID_COUNTRY` | `US` | Optional. Only used when `TFV_TAX_ID` is set. Two-letter ISO country code. Default `US`. |
| `TFV_USE_CASE_DETAILS` | (free text) | Optional. Default supplied by the workflow. Override only if you need different wording. |
| `TFV_OPT_IN_DESCRIPTION` | (free text) | Optional. Default supplied by the workflow. Override only if you need different wording. |
| `TFV_SAMPLE_MESSAGE` | `Your Cabalmail verification code is 123456` | Optional. Default matches the Cognito `sms_verification_message` template. Update if you change that template. |
| `TFV_PHONE_NUMBER_ID` | `phone-abcdef0123456789` | Optional. Auto-discovered when there is exactly one US toll-free number on the account. Set explicitly if you have more than one. |

**Secrets** (sensitive; redacted in workflow logs):

| Secret | Example | Notes |
| --- | --- | --- |
| `TFV_CONTACT_EMAIL` | `support@example.com` | Goes on the public TFV submission. Use an alias you do not mind appearing on a regulatory form. |
| `TFV_CONTACT_PHONE` | `+15551234567` | E.164 format. Same caveat as email. |
| `TFV_TAX_ID` | `12-3456789` | Business identification number (EIN for a US LLC). Leave unset for `SOLE_PROPRIETOR` entities -- carriers reject sole-proprietor submissions that include tax fields, and the workflow ignores `TFV_TAX_ID` when `TFV_BUSINESS_TYPE=SOLE_PROPRIETOR`. Stored as a secret to keep it out of workflow logs; it still appears on the public TFV submission to carriers. |
