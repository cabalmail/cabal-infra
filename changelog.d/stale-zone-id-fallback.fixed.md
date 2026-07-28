- **Suspend/revoke/reinstate no longer 500 on pre-rebuild addresses.** The
  handlers preferred the zone ID cached on the DynamoDB row at
  address-creation time over the current `DOMAINS` mapping, so rows created
  before a hosted zone was recreated pointed Route 53 calls at a zone that no
  longer exists (`NoSuchHostedZone`). The live mapping now wins; the cached
  value is only a fallback for domains dropped from `DOMAINS`.
