- **A mail tier left without sendmail is now replaced.** supervisord
  stops restarting a program that exits within five seconds of its start
  four times running, and `reconfigure.sh` restarts sendmail by killing
  it, so reconfigure messages arriving back to back could leave a tier
  with no sendmail at all. Nothing would have noticed on the IMAP tier,
  whose health check looked at Dovecot's port only, or on smtp-out,
  whose check looked at the submission ports. Both container health
  checks now also look for a sendmail process, so ECS replaces such a
  task; on the IMAP tier that part waits until sendmail's startup
  preparation has finished, so a deploy goes healthy as soon as before.
  The trains themselves are not prevented by this change (#2450).
