- Android: **Messages with many attachments send.** Attachment staging now mints presign grants in batches of 32 —
  the most `/upload_url` will issue in one call — and uploads each batch before minting the next. What a message may
  carry is bounded by its total size rather than by how many attachments one staging request may name, and grants no
  longer have to outlive the endpoint's 120-second expiry while later uploads finish.
