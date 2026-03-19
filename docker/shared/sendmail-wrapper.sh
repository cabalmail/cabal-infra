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

# ── Pre-flight diagnostics ───────────────────────────────────
# Log the state of key prerequisites so failures are easy to diagnose.
preflight_ok=true

# 1. sendmail.cf must exist
if [ ! -f /etc/mail/sendmail.cf ]; then
  echo "[sendmail-wrapper] PREFLIGHT FAIL: /etc/mail/sendmail.cf not found" >&2
  preflight_ok=false
else
  echo "[sendmail-wrapper] OK: sendmail.cf exists"
fi

# 2. Queue directory
if [ ! -d /var/spool/mqueue ]; then
  echo "[sendmail-wrapper] PREFLIGHT FAIL: /var/spool/mqueue does not exist" >&2
  preflight_ok=false
else
  echo "[sendmail-wrapper] OK: /var/spool/mqueue exists ($(ls -ld /var/spool/mqueue))"
fi

# 3. Mail user/group (confDEF_USER_ID = 8:12)
if ! getent passwd 8 >/dev/null 2>&1; then
  echo "[sendmail-wrapper] PREFLIGHT WARN: no user with UID 8 (mail)" >&2
fi
if ! getent group 12 >/dev/null 2>&1; then
  echo "[sendmail-wrapper] PREFLIGHT WARN: no group with GID 12 (mail)" >&2
fi

# 4. PID file directory writable
PIDDIR=$(dirname "$PIDFILE")
if [ ! -d "$PIDDIR" ]; then
  echo "[sendmail-wrapper] PREFLIGHT FAIL: $PIDDIR does not exist" >&2
  preflight_ok=false
elif [ ! -w "$PIDDIR" ]; then
  echo "[sendmail-wrapper] PREFLIGHT FAIL: $PIDDIR not writable" >&2
  preflight_ok=false
else
  echo "[sendmail-wrapper] OK: $PIDDIR is writable"
fi

# 5. Port 25 not already in use
if ss -tlnp 2>/dev/null | grep -q ':25 '; then
  echo "[sendmail-wrapper] PREFLIGHT WARN: port 25 already in use:" >&2
  ss -tlnp 2>/dev/null | grep ':25 ' >&2
fi

if [ "$preflight_ok" = false ]; then
  echo "[sendmail-wrapper] Pre-flight checks failed, aborting" >&2
  exit 1
fi

# ── Start sendmail ───────────────────────────────────────────
# Remove stale PID file from a previous run so we don't read it
# before sendmail has a chance to write a fresh one.
rm -f "$PIDFILE"

# Capture stderr from the fork parent — it may print the reason
# for the child's failure before exiting.
echo "[sendmail-wrapper] Starting sendmail -bd -q15m ..."
SM_ERR=$(mktemp)
if ! /usr/sbin/sendmail -bd -q15m 2>"$SM_ERR"; then
  echo "[sendmail-wrapper] sendmail failed to start (exit code $?)" >&2
  [ -s "$SM_ERR" ] && echo "[sendmail-wrapper] stderr: $(cat "$SM_ERR")" >&2
  rm -f "$SM_ERR"
  exit 1
fi
[ -s "$SM_ERR" ] && echo "[sendmail-wrapper] sendmail stderr: $(cat "$SM_ERR")" >&2
rm -f "$SM_ERR"

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
  # ── Post-mortem: dump recent maillog for the daemon's syslog output ──
  if [ -f /var/log/maillog ]; then
    echo "[sendmail-wrapper] Last 20 lines of /var/log/maillog:" >&2
    tail -20 /var/log/maillog >&2
  fi
  exit 1
fi

PID=$(cat "$PIDFILE")

# Verify the PID is actually alive (guards against a stale file
# that was written and then the process immediately died).
if ! kill -0 "$PID" 2>/dev/null; then
  echo "[sendmail-wrapper] sendmail (pid $PID) exited immediately" >&2
  if [ -f /var/log/maillog ]; then
    echo "[sendmail-wrapper] Last 20 lines of /var/log/maillog:" >&2
    tail -20 /var/log/maillog >&2
  fi
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
if [ -f /var/log/maillog ]; then
  echo "[sendmail-wrapper] Last 20 lines of /var/log/maillog:" >&2
  tail -20 /var/log/maillog >&2
fi
exit 1
