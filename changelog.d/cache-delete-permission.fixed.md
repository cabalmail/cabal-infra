- **Cached message bodies now really go away when a message does.** The API
  Lambdas share one IAM policy that granted only `s3:GetObject`/`s3:PutObject`
  on the raw-message cache bucket, so every endpoint that retires a cached
  body — `send` discarding a superseded draft, `save_draft` replacing or
  discarding one, `purge_messages`, and `empty_trash` — had its delete refused.
  An expunged draft or purged message stayed readable through `fetch_message`
  until the bucket lifecycle rule aged it out. Those four endpoints now hold
  `s3:DeleteObject` on that bucket; the rest of the fleet is unchanged.
  `empty_trash` failed silently on top of this, because the batch delete it
  uses reports a refused key inside a successful response instead of raising —
  that response is now inspected, so a future failure is logged rather than
  reported as success.
