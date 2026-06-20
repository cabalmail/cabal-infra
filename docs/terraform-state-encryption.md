# Encrypting Terraform state with SSE-KMS

By default the Terraform state bucket (`cabal-tf-backend`) uses SSE-S3: state is
encrypted at rest, but any principal with `s3:GetObject` reads it back fully
decrypted. You can upgrade an environment to **SSE-KMS under a customer-managed
key (CMK)** so that reading state also requires `kms:Decrypt` on that key. The
deploy principal holds `kms:Decrypt`; nobody else does, so broad S3 access alone
no longer exposes state.

This is opt-in per environment and entirely manual to activate. The repository
ships the mechanism; the steps below create the key and turn it on.

## How activation works

[`make-terraform.sh`](../.github/scripts/make-terraform.sh) reads one variable,
`STATE_KMS_KEY_ID`, sourced from a per-environment GitHub Actions variable:

- **Set** to a KMS key ARN: the generated `backend.tf` gets `encrypt = true` and
  `kms_key_id = <that ARN>`. State objects are written with SSE-KMS.
- **Unset/empty** (the default): the backend is the historical plaintext-SSE-S3
  block, byte-for-byte. An environment you have not activated, or one you roll
  back, behaves exactly as before.

The presence of the ARN is the on switch -- there is no separate mode flag. Every
Terraform entry point for an environment (the `infra` and `dns` builds in
`infra.yml`, plus `quiesce.yml` and `destroy_terraform.yml`) reads the same
variable, so they stay consistent automatically. Use the key **ARN**, not a bare
`alias/...`; the S3 backend's acceptance of an alias has regressed across
Terraform versions.

## Topology you need to know first

The state bucket and the deploy principals may live in **different AWS accounts**
(the bucket in a central/management account, one `terraform` IAM user per
environment in that environment's own account, reaching the bucket cross-account
through the bucket policy). Two consequences:

1. The CMK must be created in the **same account and region as the state
   bucket** -- SSE-KMS requires the key co-located with the bucket. Confirm the
   region with `aws s3api get-bucket-location --bucket cabal-tf-backend` (a
   result of `null` means `us-east-1`).
2. If the deploy principal is in a different account from the key, cross-account
   KMS use needs the grant on **both** sides: the CMK key policy must name the
   deploy principal, and that principal's own (hand-managed) IAM policy must
   allow the KMS actions on the key ARN. Granting only one side fails closed.

Throughout, `<ENV>` is the environment's `TF_VAR_ENVIRONMENT` value (e.g.
`production`), `<REGION>` is the state bucket's region, `<STATE_ACCOUNT>` is the
account that owns the bucket, and `<DEPLOY_PRINCIPAL_ARN>` is that environment's
`terraform` IAM user.

## Part 1 -- Create the per-environment CMK

Run these against the **state bucket's account and region**. One key per
environment keeps cross-environment isolation even though the bucket is shared.

Write the key policy (`key-policy.json`): account root keeps full admin so you
can never lock yourself out, and the deploy principal gets exactly the four
actions SSE-KMS and the backend need.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RootAdmin",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::<STATE_ACCOUNT>:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "DeployPrincipalUse",
      "Effect": "Allow",
      "Principal": { "AWS": "<DEPLOY_PRINCIPAL_ARN>" },
      "Action": ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
      "Resource": "*"
    }
  ]
}
```

(`"Resource": "*"` inside a key policy means "this key.")

```bash
# Create the key and capture its ARN.
aws kms create-key \
  --description "Cabalmail Terraform state - <ENV>" \
  --policy file://key-policy.json \
  --region <REGION>
# -> note KeyMetadata.KeyId and KeyMetadata.Arn from the output.

# Turn on annual rotation (KMS keeps prior backing keys, so old ciphertext stays readable).
aws kms enable-key-rotation --key-id <KEY_ID> --region <REGION>

# Give it a human-readable alias.
aws kms create-alias \
  --alias-name alias/cabal-tf-state-<ENV> \
  --target-key-id <KEY_ID> \
  --region <REGION>
```

Keep the **key ARN** (`arn:aws:kms:<REGION>:<STATE_ACCOUNT>:key/<KEY_ID>`); you
need it twice below.

## Part 2 -- Grant the deploy principal (env account)

If the deploy principal is in a different account from the key, also add this
statement to that `terraform` user's IAM policy in its own account (the
[hand-managed CI policy](./github.md)). If the key and principal share an
account and the key policy already delegates to IAM, this step is redundant but
harmless.

```json
{
  "Sid": "TerraformStateKms",
  "Effect": "Allow",
  "Action": ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
  "Resource": "<KEY_ARN>"
}
```

## Part 3a -- Greenfield: a brand-new environment

Do Parts 1-2 **before** the first infra apply, then:

1. On the environment's GitHub Environment, set the variable
   `STATE_KMS_KEY_ID` to the key ARN.
2. Bring the environment up as normal (see [setup.md](./setup.md)). The very
   first state write is already SSE-KMS -- there is nothing to migrate.

Greenfield bring-up is the one place this is easy to forget: if you create the
environment without setting `STATE_KMS_KEY_ID`, its state starts unencrypted and
you have to run the migration below. Set the variable as part of bring-up.

## Part 3b -- Migrate an existing environment

The environment already has plaintext state. Do Parts 1-2, then:

1. Set `STATE_KMS_KEY_ID` to the key ARN on the environment's GitHub
   Environment.
2. Trigger the terraform workflow for that environment (push to its branch, or
   run `infra.yml` via `workflow_dispatch`). A fresh CI runner has no cached
   backend, so plain `terraform init` adopts the new backend with no
   `-reconfigure` needed. From now on every state write is SSE-KMS.
3. **Re-key the existing object.** A no-op apply may not rewrite state, so
   re-encrypt the current object explicitly. Run this from the state bucket's
   account, while no apply is in flight, once for the `infra` key and once for
   the `dns` (`-bootstrap`) key:

   ```bash
   aws s3 cp s3://cabal-tf-backend/<ENV> s3://cabal-tf-backend/<ENV> \
     --sse aws:kms --sse-kms-key-id <KEY_ARN> \
     --metadata-directive REPLACE --region <REGION>

   aws s3 cp s3://cabal-tf-backend/<ENV>-bootstrap s3://cabal-tf-backend/<ENV>-bootstrap \
     --sse aws:kms --sse-kms-key-id <KEY_ARN> \
     --metadata-directive REPLACE --region <REGION>
   ```

Do `development` first, then `staging`, then `production`, verifying each before
moving on.

## Verify

```bash
# Expect SSE = aws:kms and the CMK ARN.
aws s3api head-object --bucket cabal-tf-backend --key <ENV> --region <REGION> \
  --query '{SSE:ServerSideEncryption,KMS:SSEKMSKeyId}'
```

Then confirm the gate actually bites: with credentials that have `s3:GetObject`
on the bucket but **no** `kms:Decrypt` on the CMK, `aws s3api get-object` for the
key must fail with `AccessDenied`. A normal `terraform plan` for the environment
should still be a clean no-op.

## Rollback

Clear the `STATE_KMS_KEY_ID` variable and re-run the workflow; the generated
backend reverts to plaintext SSE-S3 and the next apply rewrites the object
accordingly (or re-key it immediately with the `aws s3 cp` command above using
`--sse AES256` instead of `--sse aws:kms`). The deploy principal must keep
`kms:Decrypt` until no SSE-KMS object remains, or it cannot read state to roll
back. Once nothing uses the key, disable it and schedule deletion (30-day
window).

## Rotation and disaster recovery

- **Secret/key rotation** is automatic (annual) once `enable-key-rotation` is on;
  no action needed, and prior ciphertext stays readable.
- **Accidental key deletion** is recoverable within the 30-day window
  (`aws kms cancel-key-deletion`). After the window the state object is
  unreadable, but Cabalmail's state is reproducible -- the data plane restores
  from [AWS Backup](./disaster-recovery.md) and the rest re-applies from code.
- **Compromised deploy credentials**: rotate them, and revoke that principal's
  use of the key on both the key policy and its IAM policy.
