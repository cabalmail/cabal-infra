- The nightly image scan now selects the `linux/arm64` child of the
  image index (`trivy image --platform linux/arm64`). The mail tiers are
  built and run arm64-only, and with provenance attestations the ECR
  artifact is an OCI index; Trivy on the amd64 runner was defaulting to
  `linux/amd64`, finding no matching child, and failing every run.
