- **Layered configuration for the Linux client.** Settings live in a
  hand-editable `$XDG_CONFIG_HOME/cabalmail/config.toml`, resolved through a
  precedence stack — command-line flag, `CABALMAIL_*` environment variable,
  user file, `$XDG_CONFIG_DIRS` entries in order, server-synced preferences,
  built-in default — with every key recording which of those it came from.
  Three sections say how far a value travels: `[preferences]` to every device,
  `[preferences.linux]` to the user's other Linux machines, `[local]` nowhere;
  a key written in the wrong one is an error naming the section it belongs in,
  as is an unknown key or an unacceptable value, each reported with the file,
  line, and column. Client writes are atomic and preserve comments, key order,
  and alignment, so the file can be shared with an open editor. `cabalmail
  --print-config`, `cabalmail config set`, and `cabalmail config reset` drive
  it from a terminal; `config.example.toml` and the `cabalmail.5` key list are
  generated from the same table the parser reads, and a test asserts the synced
  key set matches the `set_preferences` Lambda's so a divergence fails CI
  rather than 400ing on a push. The propagation machinery that watches the file
  and pushes to the server lands with the Settings window in Phase 6. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).
