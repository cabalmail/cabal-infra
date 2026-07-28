- **Address suspend and reinstate.** New `/suspend_address` and
  `/reinstate_address` endpoints withdraw an address's DNS records (MX, SPF,
  DKIM, DMARC, BIMI) while keeping the address in DynamoDB and the mail-tier
  runtime configuration, and republish them to reverse the suspension. DNS
  records shared with an active co-tenant address on the same subdomain are
  left alone. The React rail exposes a pause/play row action (suspend behind a
  confirmation dialog, reinstate immediate) with suspended rows dimmed, the
  admin address list shows a suspended marker, and `/list` and
  `/list_addresses_admin` now return a `suspended` flag on each row.
