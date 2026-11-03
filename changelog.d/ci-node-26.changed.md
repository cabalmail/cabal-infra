- **CI Node runtime 22 → 26.** The `lint.yml`, `android.yml` and
  `extensions.yml` jobs now run on Node 26 (Active LTS) instead of Node 22,
  which enters maintenance. The webmail's deploy build in `app.yml`, which
  used the runner image's default Node, is now pinned to Node 26 too.
