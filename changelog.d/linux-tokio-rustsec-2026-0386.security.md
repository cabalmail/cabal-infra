- **tokio past the `AsyncFd` I/O-safety advisory in the Linux client.**
  `tokio` moves from 1.53.1 to 1.53.3 in `linux/Cargo.lock`
  (RUSTSEC-2026-0386). The older version's safe `AsyncFd` constructors
  accepted any raw file descriptor without proof of ownership, which could
  break I/O safety; the workspace never calls them, but the advisory turned
  the `supply-chain` gate red for every PR that runs the Rust checks.
