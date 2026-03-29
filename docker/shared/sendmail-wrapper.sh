#!/bin/bash
# Wrapper to run sendmail in the foreground for supervisord.
#
# Uses -bD (foreground daemon mode) so supervisord directly owns the
# sendmail process — no PID file monitoring, no orphan daemons.

# Kill any stale sendmail daemon orphaned from a previous wrapper run
pkill -x sendmail 2>/dev/null || true
sleep 1
rm -f /var/run/sendmail.pid

exec /usr/sbin/sendmail -bD -q15m
