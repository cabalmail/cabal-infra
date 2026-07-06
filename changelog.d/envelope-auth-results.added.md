- Envelope payloads from `/list_envelopes` and `/search_envelopes` now
  carry an `auth_results` field with the SPF/DKIM/DMARC verdicts the
  smtp-in milters stamped, parsed only from `Authentication-Results`
  headers bearing the control-domain authserv-id. `null` means no
  trusted header (pre-feature or internally-routed mail) and must render
  as "not verified", never as pass.
