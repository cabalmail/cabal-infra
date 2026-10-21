- **Distrusted emSign intermediates refused by the Linux client.**
  `rustls-webpki` moves from 0.103.15 to 0.103.16 in `linux/Cargo.lock`
  (RUSTSEC-2026-0382). The older version could accept a certificate chain
  through eMudhra's emSign intermediates, whose private keys are now public,
  when the trust store still allowed such a path. The advisory also turned the
  `supply-chain` gate red for every PR that runs the Rust checks.
