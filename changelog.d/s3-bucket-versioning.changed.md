- Enabled S3 versioning on the two infra buckets holding durable
  content - the admin bucket (React bundle plus Lambda deploy
  artifacts) and the public front-door site - so an accidental
  overwrite or delete can be rolled back. The transient cache bucket
  (two-day object expiry) is intentionally left unversioned. Clears the
  `CKV_AWS_21` / `AWS-0090` scanner findings.
