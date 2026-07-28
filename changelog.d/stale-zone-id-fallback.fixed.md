- **Suspend/revoke/reinstate no longer 500 on pre-rebuild addresses.** The
  handlers used the zone ID cached on the DynamoDB row at address-creation
  time, so rows created before a hosted zone was recreated pointed Route 53
  calls at a zone that no longer exists (`NoSuchHostedZone`). The zone is now
  always resolved from the live `DOMAINS` mapping, and the vestigial
  `zone-id` attribute is no longer written or read anywhere; leftover values
  on existing rows are inert.
