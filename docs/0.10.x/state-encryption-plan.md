# Terraform State Encryption Plan

## Context

Today, Cabalmail's Terraform state lives in the `cabal-tf-backend` S3 bucket. The bucket has SSE-S3 enabled at the bucket level (AWS default since 2023), so the state file is encrypted at rest with an AWS-owned key the service manages transparently. The catch is that with SSE-S3, **any IAM principal that can call `s3:GetObject` on the bucket gets the fully decrypted state back** — the service decrypts on read with no separate authorization step. This is the standard backend posture, and it has been adequate while the only secrets in state were resource ARNs and IDs.

The 0.7.x monitoring work surfaced a concrete case where this posture starts to chafe: the `alert_sink` Lambda needs Pushover credentials and an ntfy publisher token. The Phase 1 implementation works around the issue by writing placeholder values via Terraform and using `ignore_changes = [value]` so the operator can `aws ssm put-parameter` the real values out-of-band. That keeps secrets out of state, but at the cost of:

- Manual setup steps that are easy to skip and hard to reproduce across environments.
- Drift between code and reality — `terraform.tfstate` claims a value the operator immediately overwrote.
- No way to rotate the secret in the same flow as a normal apply.

The fix is to re-key the state object under a **customer-managed KMS key (CMK)** using the S3 backend's `encrypt` + `kms_key_id` options (SSE-KMS). With SSE-KMS and a CMK, S3 calls KMS on the caller's behalf using the *caller's* permissions, so reading state requires **both** `s3:GetObject` **and** `kms:Decrypt` on the key. Grant `kms:Decrypt` to only the deploy principal and we get the property we want: S3 read access alone no longer reveals state. That changes the calculus enough that we can comfortably manage secrets through Terraform.

### What HashiCorp Terraform can and cannot do here

An earlier draft of this plan assumed Terraform 1.10's top-level `encryption { key_provider ... }` block, which encrypts the state and plan *payload* client-side. **That block is an OpenTofu feature (OpenTofu 1.7+), not HashiCorp Terraform.** In Terraform it is still an open proposal ([hashicorp/terraform#9556](https://github.com/hashicorp/terraform/issues/9556), [#31013](https://github.com/hashicorp/terraform/issues/31013)); the canonical docs for it live on [OpenTofu's site](https://opentofu.org/docs/language/state/encryption/). This repo runs HashiCorp Terraform (`hashicorp/setup-terraform`, the `terraform` CLI), so that block would not parse.

Our lever is therefore **backend-level SSE-KMS**, not client-side encryption. The practical difference:

- A principal that *does* hold `kms:Decrypt` (the deploy principal) still sees plaintext state JSON. That is acceptable — the deploy principal is trusted with state by definition.
- Plan-file artifacts are not independently encrypted beyond the at-rest encryption GitHub Actions already applies to job artifacts.

For our threat model — an IAM principal with broad S3 access but no business reading state secrets — SSE-KMS closes the gap. Full client-side payload encryption would require migrating the toolchain to OpenTofu, which is out of scope (see Non-goals).

## Goals

- Every Terraform state object (both stacks, all environments) is encrypted at rest under a per-environment customer-managed KMS key (SSE-KMS), not the default AWS-owned SSE-S3 key.
- The deploy IAM principal is the only entity with `kms:Decrypt` on those keys, so `s3:GetObject` alone cannot read state.
- State locking moves to native S3 conditional-write locking (`use_lockfile`), closing the current gap (there is no lock table today at all) without standing up DynamoDB.
- Secrets that are seeded out-of-band today (Pushover user key, Pushover app token, ntfy publisher token, anything similar added later) can become regular Terraform inputs sourced from GitHub Actions secrets, because state is now CMK-gated. (Gated on monitoring being enabled — see Phasing.)
- Rotation of those secrets becomes "update the GitHub secret and re-run apply" — no manual `aws ssm put-parameter`.
- The migration is reversible: each step has a rollback path, and the final state is recoverable from backup if a key is accidentally deleted.

## Non-goals

- **Client-side state/plan payload encryption.** OpenTofu-only; not available in HashiCorp Terraform. SSE-KMS is the chosen mechanism.
- **Switching to OpenTofu.** A toolchain migration (swapping `terraform` -> `tofu` across every workflow, script, and doc, plus provider re-validation) is a far larger change than the marginal security gain (payload opacity against a principal who already holds `kms:Decrypt`) justifies. Revisit only if a future compliance regime demands payload-level encryption.
- **Re-keying historical state versions.** Once the current object is re-written under the CMK, prior S3 object versions remain under their old SSE-S3 encryption; we do not rewrite them. S3 versioning retention ages them out per the bucket lifecycle policy.
- **Encrypting `terraform.tfvars` files generated by CI.** They are written to a runner's ephemeral working directory, not persisted; the protection comes from masking the underlying GitHub secrets, not from file-level encryption.

## Current state (audit)

- Backend: `cabal-tf-backend` S3 bucket. `make-terraform.sh` writes a backend block with `bucket`, `key`, `region` only — **no `encrypt`, no `kms_key_id`, and no locking** (no `dynamodb_table`, no `use_lockfile`).
- State keys: `dev-bootstrap`, `stage-bootstrap`, `prod-bootstrap` (DNS stack); `dev`, `stage`, `prod` (infra stack). The key suffix is `TF_ENVIRONMENT` (= `vars.TF_VAR_ENVIRONMENT`).
- Bucket-level encryption: SSE-S3 (default-on), AWS-owned key. No bucket key, no CMK.
- All four `make-terraform.sh` callers — `infra.yml` (dns + infra), `quiesce.yml`, `destroy_terraform.yml` — generate the backend identically, so one change to the generator reaches every Terraform entry point.
- Terraform version: floors pinned at `>= 1.1.2` (most module `versions.tf`) and `>= 1.9.0` (infra root `terraform.tf`); CI uses `hashicorp/setup-terraform@v4` with no `terraform_version`, resolving to latest stable.

## Target state

### KMS keys

One CMK per environment, one alias per environment:

| Environment | Key alias                    | Purpose                          |
| ----------- | ---------------------------- | -------------------------------- |
| dev         | `alias/cabal-tf-state-dev`   | Encrypts dev `infra` + DNS state |
| stage       | `alias/cabal-tf-state-stage` | Encrypts stage state             |
| prod        | `alias/cabal-tf-state-prod`  | Encrypts prod state              |

The alias suffix tracks `TF_ENVIRONMENT` (`dev` / `stage` / `prod`), matching the existing state-key naming. One key per environment (not per stack) keeps the surface small: `infra` and `dns` for the same environment share a key; cross-environment isolation is preserved.

Key policy: the deploy principal gets `Encrypt`, `Decrypt`, `GenerateDataKey`, `DescribeKey` (S3 SSE-KMS uses `GenerateDataKey` + `Decrypt`; the rest cover Terraform's backend operations and inspection). Account root keeps full admin (per AWS best practice — never lock yourself out of your own key). Deletion window: 30 days (max). Automatic rotation: on (annual; KMS retains prior backing-key versions, so historical ciphertext stays readable and no re-encrypt is needed). Multi-region: false (state lives in one region).

### Backend changes

`make-terraform.sh` emits:

```hcl
terraform {
  backend "s3" {
    bucket       = "cabal-tf-backend"
    key          = "<env-key>"
    region       = "<region>"
    encrypt      = true
    kms_key_id   = "<cmk-or-alias-arn>"   # alias/cabal-tf-state-<env>
    use_lockfile = true
  }
}
```

Notes:

- `kms_key_id` accepts a key ARN or alias ARN. (See Open questions on whether a bare `alias/...` is accepted; lean toward the ARN emitted by key creation.)
- `use_lockfile` requires S3 versioning (already on) and that the deploy principal can put and delete the lock object. No DynamoDB table needed.
- `encrypt = true` + `kms_key_id` is what re-keys the state object from SSE-S3 to SSE-KMS. Existing objects stay SSE-S3 until the next state write re-PUTs them (see migration step 4).

### Required Terraform version

Bump every `versions.tf` / `terraform.tf` `required_version` floor to `>= 1.11`. `use_lockfile` is GA in 1.11 (experimental in 1.10), so 1.11 is the real floor. Pin `setup-terraform` to `terraform_version: "<2.0.0"` in the workflows so a future Terraform 2.x release does not surprise us.

### Generating the backend per environment

`make-terraform.sh` gains a knob so the change can roll out per environment and be cleanly reverted: a `STATE_ENCRYPTION_MODE` env var sourced from a per-GitHub-Environment variable. Values:

- `off` (default): today's plaintext-SSE-S3 backend, byte-for-byte. Greenfield-safe and the rollback target.
- `kms`: backend with `encrypt` + `kms_key_id` + `use_lockfile`.

Because all four callers reference the same per-environment variable, every Terraform entry point for a given environment stays consistent automatically. Default `off` means the generator change can land dormant on all branches and be **activated per environment** once that environment's key and grant exist — decoupling "the code is present" from "encryption is active here," which is the safety property we want when activation depends on an out-of-band key. Once all three environments are on `kms`, the default can be flipped to `kms` so new environments are encrypted by default (tracked in Open questions).

## Phasing / migration sequence

The generator is shared across both stacks, so a single code change covers `dns` and `infra`. Per environment (`dev` -> `stage` -> `prod`):

1. **Create the CMK + alias.** Manual bootstrap — `aws kms create-key` + `aws kms create-alias`, or a small `terraform/state-keys/` stack. Capture the key ARN. (See the operator runbook for exact commands and the key policy.)
2. **Grant the deploy principal** `kms:Encrypt` / `Decrypt` / `GenerateDataKey` / `DescribeKey` on the CMK, via the key policy and, if KMS-by-Terraform is not already permitted, the hand-managed per-account CI IAM policy. (KMS grants may already exist from the DNSSEC work — verify before adding.)
3. **Bump the Terraform version** floors to `>= 1.11` and pin `setup-terraform` to `<2.0.0`. Confirm `terraform plan` still no-ops on every environment (a pure version bump, no resource change).
4. **Set `STATE_ENCRYPTION_MODE=kms`** for the environment and re-run the terraform workflow. On a fresh CI runner there is no local backend cache, so plain `terraform init` adopts the new backend with no `-reconfigure`/`-migrate-state` needed. From this point every state write is SSE-KMS. Re-key the *existing* object one of two ways: let the next real apply rewrite it, or force it immediately with a server-side copy (`aws s3 cp s3://cabal-tf-backend/<key> s3://cabal-tf-backend/<key> --sse aws:kms --sse-kms-key-id <arn> --metadata-directive REPLACE`, run while no apply holds the lock). Verify with `head-object` that `ServerSideEncryption` is `aws:kms` under the CMK.
5. **(Deferred until monitoring is enabled.)** Fold the monitoring secrets into Terraform-managed inputs: drop `ignore_changes`/placeholders on `aws_ssm_parameter.pushover_user_key` / `pushover_app_token` / `ntfy_publisher_token`, add `sensitive` variables, source them from GitHub secrets, document rotation. While `TF_VAR_MONITORING=false` in every environment these resources are not deployed, so there is nothing to migrate yet; this step waits for monitoring to come back.

### Greenfield (new environment)

A brand-new environment does steps 1-2 (create key, grant principal) before the first infra apply, sets `STATE_ENCRYPTION_MODE=kms` from the start, and the very first state write is SSE-KMS — no migration. Full runbook in the operator docs.

### Per-environment ordering

`dev` first, end-to-end, so any breakage shows up cheaply; then `stage`, then `prod`. Because activation is a per-environment variable flip (not a code merge), each environment can be migrated and verified independently while the generator change sits inert on the other branches.

### Rollback

| Step                                    | Rollback                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------ |
| CMK creation                            | Disable + schedule deletion (30-day window).                                                      |
| Version bump                            | Revert `versions.tf` / `terraform.tf` + the workflow pin; no state implications.                 |
| Backend `encrypt` + `kms_key_id`        | Set `STATE_ENCRYPTION_MODE=off` and re-run; the next apply rewrites state under SSE-S3. State is readable throughout as long as the deploy principal keeps `kms:Decrypt`. |
| `use_lockfile`                          | Rides along with the mode flag; `off` removes it.                                                 |
| Secret-management switch (when adopted) | Revert the `ignore_changes` removal; re-add placeholders. Real values remain in SSM; runtime unaffected. |

## CI changes

1. The deploy IAM principal needs `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey` on the per-environment CMK (key policy grant, plus the hand-managed CI IAM policy if KMS is not already permitted there).
2. Thread `STATE_ENCRYPTION_MODE` (from the per-environment GitHub variable) into the `make-terraform.sh` invocations in `infra.yml` (dns + infra build steps), `quiesce.yml`, and `destroy_terraform.yml`.
3. **(Deferred)** Set GitHub Actions environment secrets `PUSHOVER_USER_KEY`, `PUSHOVER_APP_TOKEN`, `NTFY_PUBLISHER_TOKEN` (per environment) and pass them as `TF_VAR_*` env on the apply step — only once monitoring returns.

## Disaster recovery

- **Lost CMK (accidental deletion).** Within the 30-day deletion window: cancel the deletion. After the window: the state object is unrecoverable, but Cabalmail's state is reproducible — the data plane recovers from AWS Backup (DynamoDB + EFS) and the rest re-applies from code. Total recovery cost: hours, not days. Practice once on dev.
- **Key rotation.** Automatic annual rotation retains prior backing keys, so historical ciphertext stays readable; rotation is safe and needs no re-encrypt.
- **Lost deploy IAM credentials.** Standard rotation; no state-encryption-specific impact.
- **Compromised deploy IAM credentials.** Same, plus revoke the compromised principal's grant on the key.
- **State file corruption.** S3 versioning stays on; restore the previous version and run `terraform plan` to confirm it still reflects reality.

## Acceptance

- Each environment's state object reports `ServerSideEncryption = aws:kms` under the per-environment CMK (S3 console or `head-object`).
- A simulated read by an IAM principal with `s3:GetObject` but **without** `kms:Decrypt` on the CMK returns access-denied on the object.
- `terraform plan` still produces no diff in steady state.
- A second concurrent apply is blocked by the S3 lock object (`use_lockfile` working).
- **(When monitoring returns)** rotating the Pushover app token consists of: update `PUSHOVER_APP_TOKEN` in the prod GitHub environment, re-run the terraform workflow, observe the SSM SecureString updated; trigger a Kuma test alert and confirm delivery.
- The operator runbook (migration + greenfield) is published at the top level of `docs/` and linked from the relevant index.

## Open questions

- **`kms_key_id` form.** Confirm at implementation whether the S3 backend accepts a bare alias (`alias/cabal-tf-state-<env>`) or requires the alias ARN / key ARN. Lean: emit the key ARN from creation output.
- **Default mode flip.** Once all three environments are on `kms`, flip `make-terraform.sh`'s default from `off` to `kms` so new environments are encrypted by default. Track as a separate follow-up.
- **Single-region failover.** If a future multi-region setup lands, the per-environment CMK becomes a multi-region key with replicas. Out of scope here.

## Out of scope for 0.10.x

- Client-side state/plan payload encryption (OpenTofu).
- Application-level secrets management (e.g. moving the Cognito client secret out of state — separate posture decision).
- Hardware-backed key custody (AWS CloudHSM, KMS XKS).
- Per-secret keys vs. per-environment keys. The current per-environment design is a good default; revisit if a future compliance regime demands tighter blast radius.
