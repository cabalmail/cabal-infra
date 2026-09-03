- **Per-message attachment count limit.** Sending a message with more than
  ten attachments no longer fails with a 400. The cap was introduced on the
  premise that the clients never attach more than a handful, which the
  uncapped photo picker retires; total message size is what a recipient's
  server actually rejects, and the 25 MB server-side ceiling still bounds
  that. Clients now stage uploads in batches so the presigned-URL
  endpoint's own per-request limit no longer caps a message either.
