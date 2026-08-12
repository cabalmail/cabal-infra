- **A send retry is no longer refused past the dedupe window.** `/send` claims
  a Message-Id for ten minutes so a retry a client makes after a lost response
  cannot deliver twice, but the claim was released only by DynamoDB's TTL
  reaper, which runs best-effort and can be hours late. A repeat of the same
  Message-Id - the Apple outbox re-submits its stored one on every drain - was
  therefore refused for as long as the row happened to survive, silently,
  behind a `200 "submitted"`. The claim now expires on schedule.
