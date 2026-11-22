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
  directory its client made. The directory lives as long as its account
  is the one the install remembers. Sign-out closes the account's
  stores, so a client still held cannot write its mail back, renames the
  directory to a being-deleted name in one step and removes it; a
  removal that fails is an error in the log, and the next launch removes
  what is left. Another account's directory goes once a sign-in as
  someone else has succeeded, never when the form is submitted, so a
  mistyped username cannot take the real account's saved mail. A launch,
  before the first client is built, removes every directory but the
  remembered account's and moves the caches an earlier build left in the
  shared directory into it, replacing what is there; with no remembered
  account they are deleted. A launch that finds its stored session
  expired keeps the directory. The outbox, drafts, address list and feed
  store stay where they were, and the wipes still empty them. Phase 1 of
  `docs/1.x/post-wave-3/sqlite-mail-store.md`.
