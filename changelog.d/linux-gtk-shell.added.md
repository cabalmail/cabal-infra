- **Application shell for the Linux client.** `cabalmail` now opens a GTK4 and
  libadwaita window: an `AdwApplication` under the `com.cabalmail.Cabalmail`
  application ID, a Blueprint-defined main window compiled to a GResource at
  build time, a quit action on Ctrl+Q, and the `theme` preference applied to
  libadwaita's style manager, so `system`, `light`, and `dark` are honoured from
  the first launch. Underneath it is the piece that would be painful to
  retrofit: one tokio runtime owned by the application and a `spawn_to_ui!`
  helper that runs a future on it, hands the result to a `glib` main-context
  task, and captures widgets weakly — the single spelling every later phase's
  requests use, tested end to end before there is a request to make. Ships the
  `.desktop` entry, AppStream metadata, and application icon that packaging
  installs. The build requires `blueprint-compiler`, and it says so by name
  rather than falling back to a second UI format. There is still nothing to
  sign in to; that is Phase 3. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).
