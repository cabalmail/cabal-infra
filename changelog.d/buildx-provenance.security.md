- Container images built in CI now publish buildx provenance
  attestations (the SLSA build record, `mode=min`) to ECR alongside the
  image. The `--provenance=false` flag that suppressed them has been
  removed from both the mail-tier and certbot-renewal builds.
