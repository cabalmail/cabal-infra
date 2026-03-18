#!/bin/bash
# Wrapper to run sendmail in the foreground for supervisord.
#
# sendmail -bd forks to background by design (double-fork, re-parent to
# PID 1). This wrapper starts the daemon, waits for its PID file, and
# stays alive as long as the daemon process is running. When the wrapper
# is terminated (e.g. supervisorctl restart), it kills the daemon so the
# next wrapper instance can bind the port cleanly.
set -euo pipefail

PIDFILE=/var/run/sendmail.pid

# Kill the sendmail daemon when the wrapper is stopped by supervisord.
# Without this, the double-forked daemon survives the wrapper's death
# and holds port 25, causing the next startup to fail with EX_OSERR (71).
cleanup() {
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(cat "$PIDFILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "[sendmail-wrapper] Stopping sendmail daemon (pid $pid)..."
      kill "$pid" 2>/dev/null || true
      # Wait briefly for clean shutdown
      for i in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      # Force kill if still alive
      if kill -0 "$pid" 2>/dev/null; then
        echo "[sendmail-wrapper] Force-killing sendmail (pid $pid)" >&2
        kill -9 "$pid" 2>/dev/null || true
      fi
    fi
    rm -f "$PIDFILE"
  fi
}
trap cleanup SIGTERM SIGINT EXIT

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

# Stay alive while the sendmail daemon is running.
# Use wait-style sleep so SIGTERM interrupts immediately
# instead of blocking until the sleep completes.
while kill -0 "$PID" 2>/dev/null; do
  sleep 5 &
  wait $! 2>/dev/null || true
done

echo "[sendmail-wrapper] sendmail (pid $PID) exited" >&2
exit 1
