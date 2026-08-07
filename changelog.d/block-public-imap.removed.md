- **Public IMAP access.** Per the deprecation notice in v0.11.11, the
  NLB's IMAPS listener (993) is gone; mailbox access is now
  exclusively through the Cabalmail clients via the Lambda API, which
  reaches the imap tier privately. The `_imaps._tcp` SRV record now
  advertises "not offered" (RFC 6186) like `_imap._tcp` already did,
  and the imap tier's security group no longer admits public
  traffic - 143 is VPC-only (health checks and the Lambda API), 993
  is closed entirely. Outbound submission (465/587) is unaffected.
