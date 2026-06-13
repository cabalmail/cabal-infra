- Terraform state can be encrypted at rest under a per-environment
  customer-managed KMS key (SSE-KMS): set the `STATE_KMS_KEY_ID` GitHub
  variable for an environment to a key ARN and `make-terraform.sh` emits a
  backend with `encrypt` + `kms_key_id`, so reading that environment's
  state then requires `kms:Decrypt` in addition to `s3:GetObject`. Leaving
  the variable unset keeps the prior plaintext-SSE-S3 backend unchanged.
  See `docs/terraform-state-encryption.md`.
