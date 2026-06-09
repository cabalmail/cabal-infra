- The control domain may now also be listed in `mail_domains` to host email
  addresses on its own subdomains. Its existing bootstrap zone is reused instead
  of creating a duplicate hosted zone (which would have split name servers and
  silently blackholed one copy), and the `new`-address Lambda rejects subdomains
  that are reserved for infrastructure on the control domain (`admin`, `www`,
  `imap`, `smtp`, `smtp-in`, `smtp-out`, `mail-admin`, `cabal._domainkey`,
  `_dmarc`). The control-domain apex remains unaddressable.
