#!/bin/bash
# Wrapper to run sendmail in the foreground for supervisord.
#
# sendmail -bd forks to background by design. This wrapper starts the
# daemon, waits for its PID file, and stays alive as long as the daemon
# process is running. When sendmail exits, the wrapper exits too, so
# supervisord can detect the failure and restart.
set -euo pipefail

PIDFILE=/var/run/sendmail.pid

# Remove stale PID file from a previous run so we don't read it
# before sendmail has a chance to write a fresh one.
rm -f "$PIDFILE"

echo "[sendmail-wrapper] Starting sendmail -bd -q15m ..."
if ! /usr/sbin/sendmail -bd -q15m; then
  echo "[sendmail-wrapper] sendmail failed to start (exit code $?)" >&2
  exit 1
fi

# Wait for sendmail to create its PID file (up to 10 seconds)
for i in $(seq 1 100); do
  [ -f "$PIDFILE" ] && break
  sleep 0.1
done

if [ ! -f "$PIDFILE" ]; then
  echo "[sendmail-wrapper] sendmail failed to create PID file at $PIDFILE" >&2
  # Check common alternative locations to aid debugging
  for alt in /run/sendmail.pid /var/run/sendmail/sendmail.pid; do
    if [ -f "$alt" ]; then
      echo "[sendmail-wrapper] Found PID file at $alt instead — fix confPID_FILE" >&2
    fi
  done
  exit 1
fi

PID=$(cat "$PIDFILE")

# Verify the PID is actually alive (guards against a stale file
# that was written and then the process immediately died).
if ! kill -0 "$PID" 2>/dev/null; then
  echo "[sendmail-wrapper] sendmail (pid $PID) exited immediately" >&2
  rm -f "$PIDFILE"
  exit 1
fi
echo "[sendmail-wrapper] sendmail started (pid $PID)"

# Stay alive while the sendmail daemon is running
while kill -0 "$PID" 2>/dev/null; do
  sleep 5
done

echo "[sendmail-wrapper] sendmail (pid $PID) exited" >&2
exit 1
