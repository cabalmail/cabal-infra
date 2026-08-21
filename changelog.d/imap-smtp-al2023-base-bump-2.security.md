- **Refreshed the pinned `amazonlinux:2023` base digest again.** The `imap`,
  `smtp-in`, `smtp-out`, and `sinkhole` Dockerfiles now pin the latest
  upstream `amazonlinux:2023` multi-arch index digest, picking up patched
  `python3`, `python3-libs`, `glib2`, and `gawk` packages on next rebuild.
