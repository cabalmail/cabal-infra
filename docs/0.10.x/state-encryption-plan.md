# Terraform State Encryption Plan

## Context

Today, Cabalmail's Terraform state lives in the `cabal-tf-backend` S3 bucket. The bucket has SSE-S3 enabled at the bucket level (AWS default since 2023), so the state file is encrypted at rest with an AWS-owned key the service manages transparently. The catch is that with SSE-S3, **any IAM principal that can call `s3:GetObject` on the bucket gets the fully decrypted state back** — the service decrypts on read with no separate authorization step. This is the standard backend posture, and it has been adequate while the only secrets in state were resource ARNs and IDs.

The 0.7.x monitoring work surfaced a concrete case where this posture starts to chafe: the `alert_sink` Lambda needs Pushover credentials and an ntfy publisher token. The Phase 1 implementation works around the issue by writing placeholder values via Terraform and using `ignore_changes = [value]` so the operator can `aws ssm put-parameter` the real values out-of-band. That keeps secrets out of state, but at the cost of manual setup steps, drift between code and reality, and no in-band rotation.

The fix is to re-key the state object under a **customer-managed KMS key (CMK)** using the S3 backend's `encrypt` + `kms_key_id` options (SSE-KMS). With SSE-KMS and a CMK, S3 calls KMS on the caller's behalf using the *caller's* permissions, so reading state requires **both** `s3:GetObject` **and** `kms:Decrypt` on the key. Grant `kms:Decrypt` to only the deploy principal and we get the property we want: S3 read access alone no longer reveals state. That changes the calculus enough that we can comfortably manage secrets through Terraform.

### What HashiCorp Terraform can and cannot do here

An earlier draft of this plan assumed Terraform 1.10's top-level `encryption { key_provider ... }` block, which encrypts the state and plan *payload* client-side. **That block is an OpenTofu feature (OpenTofu 1.7+), not HashiCorp Terraform.** In Terraform it is still an open proposal ([hashicorp/terraform#9556](https://github.com/hashicorp/terraform/issues/9556), [#31013](https://github.com/hashicorp/terraform/issues/31013)); the canonical docs for it live on [OpenTofu's site](https://opentofu.org/docs/language/state/encryption/). This repo runs HashiCorp Terraform (`hashicorp/setup-terraform`, the `terraform` CLI), so that block would not parse.

Our lever is therefore **backend-level SSE-KMS**, not client-side encryption. The practical difference:

- A principal that *does* hold `kms:Decrypt` (the deploy principal) still sees plaintext state JSON. That is acceptable — the deploy principal is trusted with state by definition.
- Plan-file artifacts are not independently encrypted beyond the at-rest encryption GitHub Actions already applies to job artifacts.

For our threat model — an IAM principal with broad S3 access but no business reading state secrets — SSE-KMS closes the gap. The `encrypt` + `kms_key_id` backend options are long-standing, so this needs **no Terraform version bump**. Full client-side payload encryption would require migrating the toolchain to OpenTofu, which is out of scope (see Non-goals).

### Native state locking is a separate follow-up

There is no state lock table today; concurrent runs are serialized by a per-branch GitHub Actions concurrency group (see `docs/terraform.md`). Terraform 1.11's `use_lockfile` (native S3 locking) would add a real lock object, but the state bucket policy grants the cross-account deploy users only `s3:GetObject`/`PutObject`/`PutObjectAcl` on their **exact** state keys and **no `s3:DeleteObject`**, so a `<key>.tflock` object could be neither written nor released without a bucket-policy change. That bucket-policy work (and the 1.11 floor it implies) is deferred to its own change; this plan does not enable `use_lockfile`.

## Goals

- Every Terraform state object (both stacks, all environments) is encrypted at rest under a per-environment customer-managed KMS key (SSE-KMS), not the default AWS-owned SSE-S3 key.
- Each environment's deploy principal is the only non-admin entity that can use its CMK, so `s3:GetObject` alone cannot read state.
- Secrets seeded out-of-band today (Pushover user key, Pushover app token, ntfy publisher token, anything similar later) can become regular Terraform inputs sourced from GitHub Actions secrets, because state is now CMK-gated. (Gated on monitoring being enabled — see Phasing.)
- Rotation of those secrets becomes "update the GitHub secret and re-run apply" — no manual `aws ssm put-parameter`.
- The migration is reversible: each step has a rollback path, and the final state is recoverable from backup if a key is accidentally deleted.

## Non-goals

- **Client-side state/plan payload encryption.** OpenTofu-only; not available in HashiCorp Terraform. SSE-KMS is the chosen mechanism.
- **Switching to OpenTofu.** A toolchain migration (swapping `terraform` -> `tofu` across every workflow, script, and doc, plus provider re-validation) is a far larger change than the marginal security gain justifies.
- **Native state locking (`use_lockfile`).** Deferred to its own change; requires a cross-account bucket-policy update (add `s3:DeleteObject` and the `<key>.tflock` resources) and a Terraform 1.11 floor.
- **Re-keying historical state versions.** Once the current object is re-written under the CMK, prior S3 object versions remain under their old SSE-S3 encryption; S3 versioning retention ages them out.
- **Encrypting `terraform.tfvars` files generated by CI.** They are written to a runner's ephemeral working directory, not persisted; the protection comes from masking the underlying GitHub secrets.

## Current state (audit)

- Backend: `cabal-tf-backend` S3 bucket, in the **state/management account `101246931230`**, region **us-east-1** (`get-bucket-location` returns `null`). `make-terraform.sh` writes a backend block with `bucket`, `key`, `region` only — no `encrypt`, no `kms_key_id`, no locking.
- State keys: `development`, `staging`, `production` (infra stack); the same plus `-bootstrap` (DNS stack). The key is `TF_VAR_ENVIRONMENT` verbatim.
- Bucket-level encryption: SSE-S3 (default-on), AWS-owned key. No CMK.
- Terraform version floors: `>= 1.1.2` (most module `versions.tf`), `>= 1.9.0` (infra root `terraform.tf`). Unchanged by this plan.

### Cross-account topology

The state bucket and the deploy principals are in **different accounts**:

| Environment | `TF_VAR_ENVIRONMENT` | Deploy principal (account) |
| ----------- | -------------------- | -------------------------- |
| development | `development`        | `arn:aws:iam::175059541256:user/terraform` |
| staging     | `staging`            | `arn:aws:iam::715401949493:user/terraform` |
| production  | `production`         | `arn:aws:iam::859381087471:user/terraform` |

Each `user/terraform` reaches the state bucket (account `101246931230`) cross-account via the bucket policy, which grants `s3:GetObject`/`PutObject`/`PutObjectAcl` on that environment's exact state keys plus `s3:ListBucket`. CI authenticates as these users with static access keys (`secrets.AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`) set per GitHub Environment.

Because the bucket lives in account `101246931230`, the CMK must live there too (and in the bucket's region, us-east-1). Cross-account KMS use then requires **both** sides: the CMK key policy must grant the environment's `user/terraform`, and that user's own IAM policy must allow the KMS actions on the CMK ARN. That CI IAM policy is hand-managed per account, so the grant is added there by hand.

## Target state

### KMS keys

One CMK per environment, all in the state account `101246931230`, region us-east-1:

| Environment | Key alias                            | Key policy grants (beyond root admin)        |
| ----------- | ------------------------------------ | -------------------------------------------- |
| development | `alias/cabal-tf-state-development`   | `175059541256:user/terraform`                |
| staging     | `alias/cabal-tf-state-staging`       | `715401949493:user/terraform`                |
| production  | `alias/cabal-tf-state-production`    | `859381087471:user/terraform`                |

One key per environment keeps cross-environment isolation even though the bucket is shared: compromise of one environment's `user/terraform` grants decrypt on only that environment's key. Key policy: account root keeps full admin; the environment's `user/terraform` gets `Encrypt`, `Decrypt`, `GenerateDataKey`, `DescribeKey`. Deletion window: 30 days. Automatic rotation: on (KMS retains prior backing keys, so historical ciphertext stays readable). Multi-region: false.

### Backend changes

`make-terraform.sh` emits, when encryption is active:

```hcl
terraform {
  backend "s3" {
    bucket     = "cabal-tf-backend"
    key        = "<env-key>"
    region     = "<region>"
    encrypt    = true
    kms_key_id = "<cmk-arn>"
  }
}
```

`kms_key_id` is the CMK's key ARN, supplied via the `STATE_KMS_KEY_ID` variable. We use the ARN rather than a bare `alias/...`, whose S3-backend support has regressed across Terraform versions.

### Generating the backend per environment

`make-terraform.sh` uses a single knob: a `STATE_KMS_KEY_ID` env var sourced from a per-GitHub-Environment variable, holding the CMK's key ARN.

- **Set** (non-empty): the generator emits an encrypted backend (`encrypt` + `kms_key_id`).
- **Unset/empty** (default): today's plaintext-SSE-S3 backend, byte-for-byte. Greenfield-safe and the rollback target.

The presence of the key ARN *is* the on switch — there is no separate mode flag. Because all four callers (`infra.yml` dns + infra, `quiesce.yml`, `destroy_terraform.yml`) reference the same per-environment variable, every Terraform entry point for a given environment stays consistent automatically. An unset variable means the generator change can land dormant on all branches and be **activated per environment** once that environment's CMK and IAM grant exist.

## Phasing / migration sequence

The generator knob and the CI wiring have shipped; what remains per environment is operational. The full operator runbook — greenfield and migration — lives at [docs/terraform-state-encryption.md](../terraform-state-encryption.md).

Per environment (`development` -> `staging` -> `production`):

1. **Create the CMK + alias** in the state account (`101246931230`), region us-east-1, with a key policy granting account root admin and the environment's `user/terraform`. Capture the key ARN.
2. **Grant the environment's `user/terraform`** `kms:Encrypt`/`Decrypt`/`GenerateDataKey`/`DescribeKey` on the CMK ARN in that user's hand-managed IAM policy (the env account). Cross-account KMS needs the grant on both the key policy and the principal's policy.
3. **Set the `STATE_KMS_KEY_ID` variable** for the environment to the CMK's key ARN and re-run the terraform workflow. On a fresh CI runner there is no local backend cache, so plain `terraform init` adopts the new backend with no `-reconfigure`/`-migrate-state` needed. From this point every state write is SSE-KMS. Re-key the *existing* object either by letting the next real apply rewrite it, or immediately with a server-side copy run by the state-account owner (`aws s3 cp s3://cabal-tf-backend/<key> s3://cabal-tf-backend/<key> --sse aws:kms --sse-kms-key-id <arn> --metadata-directive REPLACE`). Verify with `head-object` that `ServerSideEncryption` is `aws:kms` under the CMK.
4. **(Deferred until monitoring is enabled.)** Fold the monitoring secrets into Terraform-managed inputs: drop `ignore_changes`/placeholders on `aws_ssm_parameter.pushover_user_key` / `pushover_app_token` / `ntfy_publisher_token`, add `sensitive` variables, source them from GitHub secrets, document rotation. While `TF_VAR_MONITORING=false` in every environment these resources are not deployed, so there is nothing to migrate yet.

### Greenfield (new environment)

A brand-new environment does steps 1-2 (create key, grant principal) before the first infra apply, sets `STATE_KMS_KEY_ID` to the new key's ARN from the start, and the very first state write is SSE-KMS — no migration.

### Per-environment ordering

`development` first, end-to-end, so any breakage shows up cheaply; then `staging`, then `production`. Because activation is a per-environment variable, each environment migrates and verifies independently while the generator change sits inert on the other branches.

### Rollback

| Step                             | Rollback                                                                                          |
| -------------------------------- | ------------------------------------------------------------------------------------------------ |
| CMK creation                     | Disable + schedule deletion (30-day window).                                                      |
| Backend `encrypt` + `kms_key_id` | Clear the `STATE_KMS_KEY_ID` variable and re-run; the next apply rewrites state under SSE-S3. State is readable throughout as long as the deploy principal keeps `kms:Decrypt`. |
| Secret-management switch (later) | Revert the `ignore_changes` removal; re-add placeholders. Real values remain in SSM; runtime unaffected. |

## CI changes

1. Each environment's `user/terraform` needs `kms:Encrypt`/`Decrypt`/`GenerateDataKey`/`DescribeKey` on that environment's CMK — granted on both the CMK key policy (state account) and the user's hand-managed IAM policy (env account). No S3 bucket-policy change is needed for encryption (the existing `GetObject`/`PutObject` grants suffice).
2. **(Shipped)** `STATE_KMS_KEY_ID` (from the per-environment GitHub variable) is threaded into the `make-terraform.sh` invocations in `infra.yml` (dns + infra build steps), `quiesce.yml`, and `destroy_terraform.yml`.
3. **(Deferred)** Set GitHub Actions environment secrets `PUSHOVER_USER_KEY`, `PUSHOVER_APP_TOKEN`, `NTFY_PUBLISHER_TOKEN` and pass them as `TF_VAR_*` env on apply — only once monitoring returns.

## Disaster recovery

- **Lost CMK (accidental deletion).** Within the 30-day window: cancel the deletion. After: the state object is unrecoverable, but Cabalmail's state is reproducible — the data plane recovers from AWS Backup (DynamoDB + EFS) and the rest re-applies from code. Hours, not days. Practice once on development.
- **Key rotation.** Automatic annual rotation retains prior backing keys, so historical ciphertext stays readable; rotation is safe and needs no re-encrypt.
- **Lost/compromised deploy credentials.** Standard rotation; for compromise, also revoke that principal's grant on the key (both the key policy and the principal's IAM policy).
- **State file corruption.** S3 versioning stays on; restore the previous version and `terraform plan` to confirm.

## Acceptance

- Each environment's state object reports `ServerSideEncryption = aws:kms` under the per-environment CMK (S3 console or `head-object`).
- A principal with `s3:GetObject` but without `kms:Decrypt` on the CMK gets access-denied on the object.
- `terraform plan` is a no-op in steady state.
- **(When monitoring returns)** rotating a Pushover token is: update the GitHub secret, re-run the workflow, observe the SSM SecureString update.
- The operator runbook (migration + greenfield) is published at `docs/terraform-state-encryption.md` and linked from the operations index.

## Open questions

- **Encrypt-by-default for new environments.** Activation is a per-environment variable, so greenfield bring-up must remember to set `STATE_KMS_KEY_ID` before the first apply. The greenfield runbook calls this out; consider a bring-up checklist guard so a new environment is never created unencrypted.
- **Native locking follow-up.** Enabling `use_lockfile` later means updating the bucket policy (add `s3:DeleteObject` and `<key>.tflock` resources for each environment) and bumping the Terraform floor to 1.11. Worth doing once this lands, since `quiesce.yml` and `infra.yml` can apply the same stack from different workflows and the per-branch concurrency group does not serialize across them.

## Out of scope for 0.10.x

- Client-side state/plan payload encryption (OpenTofu).
- Native state locking (`use_lockfile`) — separate follow-up.
- Application-level secrets management (e.g. moving the Cognito client secret out of state).
- Hardware-backed key custody (AWS CloudHSM, KMS XKS).
- Per-secret keys vs. per-environment keys.
