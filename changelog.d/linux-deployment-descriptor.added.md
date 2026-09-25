- **Deployment descriptor for the Linux client.** `cabalmail-kit` fetches
  `https://{control_domain}/config.json` and decodes it into a `Deployment`
  carrying the mail domains, API endpoint, and Cognito pool. It refuses a
  descriptor whose API endpoint is not HTTPS or that names a different control
  domain from the one it was fetched from. Each fetch is cached at
  `$XDG_CACHE_HOME/cabalmail/deployment.json`, and the cache answers only when
  the deployment cannot be reached, times out, or answers with a retryable
  status. Every kit request goes through one HTTP client: `reqwest` on rustls
  with the system trust store, HTTPS only on every redirect, and bounded by
  timeouts. The Arch package builds with LTO off, which the TLS library's C
  code requires. A new workspace check fails if the kit's descriptor fixture
  drifts from the keys Terraform's `config.json` template and `domains` module
  write.
