- **Public SMTP submission.** The NLB's submission listeners (465 and
  587) are gone; sending is now exclusively through the Cabalmail
  clients via the Lambda API, which reaches the smtp-out tier privately.
  The `_submission._tcp` SRV record now advertises "not offered"
  (RFC 6186), and the smtp-out tier's security group no longer admits
  public traffic - 465/587 are VPC-only (health checks and the send
  Lambda). Inbound relay (25) is unaffected, as is IMAP.
