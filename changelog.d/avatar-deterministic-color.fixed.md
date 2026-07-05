- Apple clients: the initials-avatar background color for a sender with no
  BIMI logo or contact photo is now deterministic across app launches. It
  previously used Swift's per-process-seeded `String.hashValue`, so the same
  correspondent could show a different color each time the app was launched.
