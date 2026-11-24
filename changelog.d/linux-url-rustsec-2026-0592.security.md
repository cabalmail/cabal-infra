- **Linux client: `url` 2.5.9 for RUSTSEC-2026-0592.** `url` 2.5.8 and
  earlier overflowed the stack in `Url::origin()` on a URL with deeply
  nested `blob:` prefixes, which aborts the process. The client reaches
  `url` only through `reqwest`, so this is a lockfile bump
  (`linux/Cargo.lock`: `url` 2.5.8 to 2.5.9, and `form_urlencoded` 1.2.2
  to 1.2.3 with it) and no source change. The advisory had turned the
  `cargo deny` step of the Linux gate red for any pull request that runs
  it.
