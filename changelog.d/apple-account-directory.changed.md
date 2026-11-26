- **A directory per account for the Apple clients' mail caches.** The
  saved message lists, message bodies and folder state now open in
  `Application Support/Cabalmail/accounts/<name>/`, where the name is a
  SHA-256 of the server and the username as typed, so two usernames that
  differ only by case get two directories on the Mac's case-insensitive
  disk too. The session lifecycle tells the client factory whose client
  it is building (`CabalmailClient.make(…, account:)`): the server and
  username typed at a sign-in, the remembered ones at a restore or for a
  client lent to background work. A process-wide registry gives every
  client of one account the same cache objects and one Spotlight indexer
  with one feed, where each client used to open its own over one shared
  directory. A sign-in that is refused or cancelled removes the
  directory its client made. The outbox, drafts, address list and feed
  store stay where they were, and the wipes still empty everything,
  including the caches an earlier build left in the shared directory.
  First half of Phase 1 of `docs/1.x/post-wave-3/sqlite-mail-store.md`;
  the migration of the existing caches follows in the same release.
