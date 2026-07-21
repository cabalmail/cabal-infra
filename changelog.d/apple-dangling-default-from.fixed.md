- Apple: **Compose no longer pre-fills a From address the account can't
  send from.** A default From address that isn't in the account's own
  address list — one revoked from another device, or one that leaked in
  from a different account before settings were account-scoped and then
  kept re-applying at sign-in via the server-synced copy — is now cleared
  when the address list loads (in compose and in Settings), and the
  cleared value is pushed to the server so the synced copy heals too.
  Settings previously masked the dangling value as "None" while compose
  kept using it, with no way to remove it from the UI. Also hardened the
  sign-out path so a preference fetch still in flight for the previous
  account is discarded instead of being applied to the next account.
