- Android: **Envelope, body, and address caches.** Room-backed envelope
  cache (LRU-bounded working window, UIDVALIDITY-mismatch invalidation),
  disk LRU cache for fetched message bodies (200 MB default cap, atomic
  writes), and an in-memory address repository whose favorites-first
  ordering feeds both the address list and the compose From picker
  (Phase 3 remainder).
