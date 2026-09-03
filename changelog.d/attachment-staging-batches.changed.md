- **Batched attachment staging in the React composer.** `/upload_url` mints at most 32 presign grants per call, so a
  message with more attachments than that failed the moment it was staged — after every file had already uploaded to
  S3. The composer now stages in batches of 32, minting each batch immediately before its own uploads, so what a
  message may carry is bounded by its total size rather than by the shape of one staging request. Minting late also
  keeps every grant inside the endpoint's 120-second expiry, which a single up-front mint for a large bundle can
  outlive.
