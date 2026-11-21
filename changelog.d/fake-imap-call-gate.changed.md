- **`FakeImapClient`'s hold on a wire call is a type of its own.** The
  shared IMAP test double's hold-and-release machinery (the search hold
  and the per-call hold some sixty suites order their races with) moves
  into `CallGate`, a value the fake stores and mutates, so holding a call
  adds no suspension point and no test changes. The fake's body drops
  from 248 to 225 of SwiftLint's 250 counted lines, which leaves room for
  the next script added to it. `FakeImapClientHoldTests` pins each rule
  of the hold on its own. Test support only: no app or Kit source
  changes.
