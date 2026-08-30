- **Eager-create pending addresses.** `POST /new` accepts a `pending` flag
  that marks an address created ahead of use (the browser extension's
  commit-time create, giving DNS and the sendmail tier runway before a
  verification mail arrives). A new `POST /confirm_address` endpoint clears
  the flag on form submit; the imap tier clears it the moment mail actually
  arrives at the address (a generated procmail rule spools a signal that a
  root drain daemon applies); and an hourly `reap_pending_addresses`
  scheduler Lambda revokes addresses still pending after 24h, including
  their DNS records and mail-tier configuration. `GET /list` now reports
  the flag so clients can badge unconfirmed addresses.
