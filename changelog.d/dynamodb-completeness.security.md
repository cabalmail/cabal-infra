- The `cabal-counter` DynamoDB table (source of truth for OS user IDs)
  now has point-in-time recovery, explicit server-side encryption, and
  deletion protection. Every other identity- or data-bearing table
  (`cabal-addresses`, `cabal-user-preferences`,
  `cabal-user-domain-access`, `cabal-dmarc-reports`) gains deletion
  protection too, so a destroy plan cannot drop them until the flag is
  flipped off in a prior apply. The TTL-reaped `cabal-rate-limits`
  table is deliberately left unprotected.
