- **Refreshed the pinned `amazonlinux:2023` base digest.** The `imap`,
  `smtp-in`, `smtp-out`, and `sinkhole` Dockerfiles now pin the current
  upstream `amazonlinux:2023` image, picking up patched `python3`,
  `python3-libs`, `glib2`, and `gawk` packages on next rebuild.
