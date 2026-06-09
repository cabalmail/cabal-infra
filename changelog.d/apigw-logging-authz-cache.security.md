- API Gateway no longer logs at `INFO` (execution logs drop to `ERROR`), the
  Cognito authorizer result cache drops from 300s to 60s so a revoked token is
  refused within a minute, and the per-method response cache is disabled on
  user-personalised read endpoints (`list_envelopes`, `fetch_message`,
  `list_attachments`, `fetch_attachment`, `fetch_inline_image`) so cached
  private data cannot outlive an authorization change. The shared `fetch_bimi`
  cache (keyed by sender domain, identical for every caller) is unchanged.
