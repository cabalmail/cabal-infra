- **Deployment descriptor for the Linux client.** `cabalmail-kit` fetches
  `https://{control_domain}/config.json`, always over HTTPS, and decodes it
  into a `Deployment` carrying the mail domains, API endpoint, and Cognito
  pool, refusing one whose API endpoint is not HTTPS. The control domain comes
  from the `control_domain` setting. Each fetch is cached at
  `$XDG_CACHE_HOME/cabalmail/deployment.json`, and the cache answers only when
  the deployment cannot be reached or answers with a retryable status - a
  refusal or an undecodable descriptor is reported, and another deployment's
  cache answers nothing. The kit's HTTP stack is `reqwest` on the system
  OpenSSL, which joins the Arch package's dependencies. A new workspace check
  fails if the kit's descriptor fixture drifts from the keys Terraform's
  `config.json` template writes.
