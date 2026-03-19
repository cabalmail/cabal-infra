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
  # Log the daemon options so we can verify sendmail will listen on port 25
  DAEMON_OPTS=$(grep -i 'DaemonPortOptions' /etc/mail/sendmail.cf 2>/dev/null || echo "(none found)")
  echo "[sendmail-wrapper] sendmail.cf DaemonPortOptions: $DAEMON_OPTS"
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

# 5. Kill any orphaned sendmail daemon still holding the port.
#    This handles the case where the previous wrapper was killed
#    (SIGKILL, OOM, etc.) and its EXIT trap never ran, leaving the
#    daemon alive on port 25 with no wrapper to manage it.
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[sendmail-wrapper] Killing orphaned sendmail daemon (pid $OLD_PID) from stale PID file..."
    kill "$OLD_PID" 2>/dev/null || true
    for i in $(seq 1 10); do
      kill -0 "$OLD_PID" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$OLD_PID" 2>/dev/null; then
      echo "[sendmail-wrapper] Force-killing orphaned daemon (pid $OLD_PID)" >&2
      kill -9 "$OLD_PID" 2>/dev/null || true
      sleep 0.5
    fi
  fi
  rm -f "$PIDFILE"
fi

# Also kill any process on port 25 that we don't have a PID file for.
# IMPORTANT: Use ss -tanp (ALL socket states), not ss -tlnp (LISTEN only).
# A bound-but-not-yet-listening socket still blocks bind() with EADDRINUSE
# but is invisible to -l.  Also check /proc/net/tcp as a belt-and-suspenders
# fallback (port 25 = hex 0019).
echo "[sendmail-wrapper] Checking for anything on port 25..."
echo "[sendmail-wrapper] /proc/net/tcp port 25 entries:"
grep -i ':0019 ' /proc/net/tcp /proc/net/tcp6 2>/dev/null | while IFS= read -r line; do
  echo "[sendmail-wrapper]   $line"
done || true
echo "[sendmail-wrapper] ss -tanp port 25:"
ss -tanp 2>/dev/null | grep ':25 ' | while IFS= read -r line; do
  echo "[sendmail-wrapper]   $line"
done || true
echo "[sendmail-wrapper] ss -tlnp port 25:"
ss -tlnp 2>/dev/null | grep ':25 ' | while IFS= read -r line; do
  echo "[sendmail-wrapper]   $line"
done || true

# Try to find the PID via ss -tanp (all states, not just LISTEN)
PORT25_PID=$(ss -tanp 2>/dev/null | grep ':25 ' | grep -oP 'pid=\K\d+' | head -1 || true)
if [ -n "$PORT25_PID" ]; then
  echo "[sendmail-wrapper] Killing process $PORT25_PID holding port 25 (found via ss)..."
  kill "$PORT25_PID" 2>/dev/null || true
  sleep 1
  if kill -0 "$PORT25_PID" 2>/dev/null; then
    kill -9 "$PORT25_PID" 2>/dev/null || true
    sleep 0.5
  fi
fi

# Fallback: try fuser if available (catches things ss might miss)
if command -v fuser >/dev/null 2>&1; then
  FUSER_OUT=$(fuser 25/tcp 2>&1 || true)
  if [ -n "$FUSER_OUT" ]; then
    echo "[sendmail-wrapper] fuser 25/tcp: $FUSER_OUT"
    fuser -k 25/tcp 2>/dev/null || true
    sleep 1
  fi
fi

# Also list ALL sendmail processes — if make or the package started one,
# we'll see it here.
echo "[sendmail-wrapper] All sendmail processes:"
ps aux 2>/dev/null | grep '[s]endmail' | while IFS= read -r line; do
  echo "[sendmail-wrapper]   $line"
done || true

if [ "$preflight_ok" = false ]; then
  echo "[sendmail-wrapper] Pre-flight checks failed, aborting" >&2
  exit 1
fi

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

# ── Post-startup diagnostics ─────────────────────────────────
# Verify the daemon is actually what we think it is and is listening.
echo "[sendmail-wrapper] Process details: $(ps -p "$PID" -o pid=,ppid=,comm=,args= 2>/dev/null || echo 'ps failed')"
echo "[sendmail-wrapper] All listeners:"
ss -tlnp 2>/dev/null | while IFS= read -r line; do
  echo "[sendmail-wrapper]   $line"
done

# Give sendmail a moment to finish opening sockets (PID file is written
# before daemon sockets are opened on some builds).
sleep 2

# Verify port 25 is actually accepting connections
if ss -tlnp 2>/dev/null | grep -q ':25 '; then
  echo "[sendmail-wrapper] HEALTH OK: port 25 is listening"
else
  echo "[sendmail-wrapper] HEALTH FAIL: port 25 is NOT listening after startup!" >&2
  echo "[sendmail-wrapper] ss -tlnp output:"
  ss -tlnp 2>/dev/null >&2
  if [ -f /var/log/maillog ]; then
    echo "[sendmail-wrapper] Last 30 lines of /var/log/maillog:" >&2
    tail -30 /var/log/maillog >&2
  fi
  echo "[sendmail-wrapper] sendmail.cf DaemonPortOptions:"
  grep -i 'DaemonPortOptions' /etc/mail/sendmail.cf 2>/dev/null >&2 || echo "(none)" >&2
  # Don't exit — let the monitoring loop handle it; the daemon may
  # recover or we'll get more diagnostic data on the next check.
fi

# Stay alive while the sendmail daemon is running.
# Use wait-style sleep so SIGTERM interrupts immediately
# instead of blocking until the sleep completes.
# Also periodically verify port 25 is still listening.
PORT_CHECK_COUNT=0
while kill -0 "$PID" 2>/dev/null; do
  sleep 5 &
  wait $! 2>/dev/null || true
  PORT_CHECK_COUNT=$((PORT_CHECK_COUNT + 1))
  # Check port 25 every ~60 seconds (12 × 5s)
  if [ $((PORT_CHECK_COUNT % 12)) -eq 0 ]; then
    if ! ss -tlnp 2>/dev/null | grep -q ':25 '; then
      echo "[sendmail-wrapper] HEALTH WARN: port 25 no longer listening (pid $PID still alive)!" >&2
      echo "[sendmail-wrapper] ss -tlnp:" >&2
      ss -tlnp 2>/dev/null >&2
      echo "[sendmail-wrapper] Process: $(ps -p "$PID" -o pid=,ppid=,stat=,comm=,args= 2>/dev/null)" >&2
    fi
  fi
done

echo "[sendmail-wrapper] sendmail (pid $PID) exited" >&2
if [ -f /var/log/maillog ]; then
  echo "[sendmail-wrapper] Last 20 lines of /var/log/maillog:" >&2
  tail -20 /var/log/maillog >&2
fi
exit 1
