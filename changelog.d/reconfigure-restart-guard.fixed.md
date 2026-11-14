- **Reconfigure messages arriving back to back can no longer stop
  sendmail on a mail tier.** `reconfigure.sh` restarts sendmail by
  killing it, a pass takes about five seconds, and supervisord counts an
  exit within five seconds of a start as a failed start and gives up
  after four in a row. Stage logged three in a row three times; prod's
  closest calls cleared the five seconds by 25 ms, in trains of up to
  ten restarts set off by rule saves. Two changes: the script now waits
  until the sendmail supervisord started has been up 15 seconds before
  killing it, so a kill can never be a failed start; and a pass started
  by a queue message restarts sendmail only when a file sendmail reads
  has changed since it started, which a rule save, a flag change or a
  confirmed address never does. The 15-minute fallback pass restarts
  sendmail regardless, as before (#2450).
