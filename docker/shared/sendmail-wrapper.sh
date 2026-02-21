#!/bin/bash
# Wrapper to run sendmail in the foreground for supervisord.
#
# sendmail -bd forks to background by design. This wrapper starts the
# daemon, waits for its PID file, and stays alive as long as the daemon
# process is running. When sendmail exits, the wrapper exits too, so
# supervisord can detect the failure and restart.
set -uo pipefail

/usr/sbin/sendmail -bd -q15m

PIDFILE=/var/run/sendmail.pid

# Wait for sendmail to create its PID file (up to 5 seconds)
for i in $(seq 1 50); do
  [ -f "$PIDFILE" ] && break
  sleep 0.1
done

if [ ! -f "$PIDFILE" ]; then
  echo "[sendmail-wrapper] sendmail failed to create PID file" >&2
  exit 1
fi

PID=$(cat "$PIDFILE")
echo "[sendmail-wrapper] sendmail started (pid $PID)"

# Stay alive while the sendmail daemon is running
while kill -0 "$PID" 2>/dev/null; do
  sleep 5
done

echo "[sendmail-wrapper] sendmail (pid $PID) exited" >&2
exit 1
