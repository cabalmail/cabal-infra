- **Durable smtp-in relay queue.** Inbound mail the relay has accepted
  but not yet handed to the imap tier now waits in a shared EFS-backed
  queue (per-tier access point, mirroring the smtp-out arrangement)
  instead of the container's ephemeral filesystem. Previously, a smtp-in
  task replacement destroyed any messages deferred in its queue — the
  silent-loss window observed when an imap deploy and a smtp-in deploy
  overlap, since mail accepted during the imap gap was queued on the
  outgoing task and killed with it, with no bounce. A replaced task's
  queue is now drained by whichever sibling task next scans it. The
  smtp-in task also gains the 120 s stop grace (supervisord
  `stopwaitsecs=110`) so an in-flight relay delivery finishes before
  SIGKILL.
