- **Multipart-upload cleanup on the cache bucket.** The
  `cache.<control_domain>` lifecycle configuration now aborts multipart
  uploads that have not completed after seven days, matching the two
  access-log buckets. Attachment staging (presigned PUTs from the admin
  client) and Lambda-side uploads both use multipart above boto3's
  threshold, and parts left behind by an interrupted upload are billed
  while remaining invisible in an object listing. Clears `CKV_AWS_300`
  from the scanner baseline.
