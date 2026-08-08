- **Core library skeleton for the Linux client.** `cabalmail-kit` gains its
  module layout — config, auth, secret storage, API client, models, MIME,
  caches, compose, outbox, policy, and preferences — together with the
  `CabalmailError` taxonomy every one of them returns. Errors classify
  themselves as transient or permanent, which is what lets the outbox queue a
  send that lost the network while surfacing one the server refused, and each
  case renders a plain sentence rather than a debug form. Still no user-facing
  functionality; the crate has no GTK, libadwaita, or WebKit dependency, so its
  tests run with no display server. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).
