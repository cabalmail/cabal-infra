- Inbound mail is now verified against the sender's SPF, DKIM, and DMARC
  records at the smtp-in relay (OpenDKIM in verify mode plus OpenDMARC in
  monitor mode, built from source for AL2023). Verdicts are stamped as an
  `Authentication-Results` header under the control-domain authserv-id,
  and forged inbound headers claiming that authserv-id are stripped.
  Observe-only: no message is rejected or quarantined regardless of the
  sender's published policy.
