- The EFS mailstore's `CKV2_AWS_18` scanner finding (Backup-plan
  membership) moved from an opaque per-resource baseline grandfather to
  a co-located inline `#checkov:skip` with rationale. The mailstore is
  already in the AWS Backup selection when `var.backup` is set; the
  graph check cannot trace that count-gated, cross-module reference, so
  the finding is a false positive. The infra checkov baseline shrinks by
  one entry. No infrastructure change.
