#!/bin/bash
# Wrapper to run sendmail in the foreground for supervisord.
#
# Uses -bD (foreground daemon mode) so supervisord directly owns the
# sendmail process - no PID file monitoring, no orphan daemons.

# Kill any stale sendmail daemon orphaned from a previous wrapper run
pkill -x sendmail 2>/dev/null || true
sleep 1
rm -f /var/run/sendmail.pid

# smtp-out only: the MTA queue is mounted from EFS (shared across all
# smtp-out tasks so a replaced task hands off its retries to a sibling -
# see docs/0.9.x/smtp-out-queue-persistence-plan.md). The access point's
# creation_info sets root:mail mode 0700 on first creation, but a stale
# directory from a previous deploy or operator action could still drift;
# re-assert the rpm default ownership and mode immediately before exec.
# No-op on subsequent boots when ownership already matches.
if [ "${TIER:-}" = "smtp-out" ]; then
  chown root:mail /var/spool/mqueue 2>/dev/null || true
  chmod 0700 /var/spool/mqueue 2>/dev/null || true
fi

exec /usr/sbin/sendmail -bD -q15m
