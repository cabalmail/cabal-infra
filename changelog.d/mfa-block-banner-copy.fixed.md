- **Stale "Admin accounts" copy on the MFA sign-in block.** The
  `require_admin_mfa` gate has covered all human users since the
  all-users extension, but the React sign-in banner still claimed
  "Admin accounts require multi-factor authentication". The fallback
  banner (shown when no enrollment client is configured) now matches
  the gate's actual scope.
