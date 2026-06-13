- Each Lambda zip uploaded by CI now ships a `*.zip.manifest.json`
  build-provenance sidecar (sha256, git commit, dirty flag, build
  timestamp, builder identity, runner OS, and workflow-run URL) next to
  the zip in S3. Terraform does not consume it yet; it records, per
  artefact, exactly which commit and run produced the bytes so a later
  step can cross-check the deployed `source_code_hash`.
