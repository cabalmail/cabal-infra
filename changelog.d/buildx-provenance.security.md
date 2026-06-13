- Mail-tier container images built in CI now publish buildx provenance
  attestations (the SLSA build record, `mode=min`) to ECR alongside the
  image; the `--provenance=false` flag that suppressed them is removed
  from those builds. The certbot-renewal image keeps provenance off
  because it is a Lambda container image and Lambda rejects the
  multi-manifest index that an attached attestation produces.
