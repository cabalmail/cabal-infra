- **Monitoring probes the IMAP path that carries mail.** The blackbox job that
  probed the removed `imap.<control-domain>:993` listener is replaced by an
  `imap_starttls` probe of `imap.cabal.internal:143` - plain TCP upgraded with
  STARTTLS, which is what the API Lambdas do. Cert-expiry coverage is
  unchanged: the ACM control-domain cert is observed on the CloudFront HTTPS
  probe and the Let's Encrypt mail cert on submission `:465`. The Kuma
  monitor, its `alert_sink` runbook key, the Mail Tiers dashboard panels, the
  cert-expiry and probe-failure runbooks, and `docs/monitoring.md` follow;
  a new unit test pins the monitor names in the docs to the runbook map so
  the two cannot drift apart silently again.
