- **Mail-tier images now build against current Amazon Linux packages.** AL2023
  resolves `$releasever` from the base image's own release snapshot, so `dnf`
  in the `imap`, `smtp-in`, `smtp-out`, and `sinkhole` builds only ever saw the
  package set frozen when that base image was published — security updates AWS
  shipped afterwards were invisible, and rebuilding picked up none of them.
  Base packages such as `openssl-libs` were worse off still: named in no
  install line, they kept the base image's versions indefinitely. All four
  Dockerfiles now track the current snapshot and upgrade before installing.
  This clears the standing Trivy backlog on `apr-util`, `openssl`, and
  `rsyslog`, whose fixed builds had been published for weeks.
