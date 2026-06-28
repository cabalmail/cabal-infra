- Infra: the three S3 content buckets (`admin`, `www`, and `cache` under the
  control domain) now deliver server access logs to a new shared,
  access-controlled log bucket (`cabal-s3-access-logs-<account>`: versioned,
  encrypted, public-access-blocked, 180-day retention), giving each an audit
  trail of object-level access. Clears the `CKV_AWS_18` / `AWS-0089` scanner
  findings.
