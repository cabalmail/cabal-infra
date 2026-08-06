#!/bin/bash
# Wrapper to run sendmail in the foreground for supervisord.
#
# Uses -bD (foreground daemon mode) so supervisord directly owns the
# sendmail process - no PID file monitoring, no orphan daemons.

# Sendmail's prerequisites (sendmail.cf, hash maps, aliases) are produced
# by prepare-sendmail.sh - in the background via supervisord on imap so
# Dovecot starts first, inline in the entrypoint on the smtp tiers. Block
# until they exist; exec'ing sendmail without sendmail.cf would just
# crash-loop. Phase 3 of docs/0.10.x/imap-deploy-downtime-plan.md.
if [ ! -f /run/sendmail-ready ]; then
  echo "[sendmail-wrapper] Waiting for sendmail prerequisites (/run/sendmail-ready)..."
  until [ -f /run/sendmail-ready ]; do
    sleep 1
  done
  echo "[sendmail-wrapper] Prerequisites ready."
fi

# Kill any stale sendmail daemon orphaned from a previous wrapper run
pkill -x sendmail 2>/dev/null || true
sleep 1
rm -f /var/run/sendmail.pid

# smtp-out and smtp-in: the MTA queue is mounted from EFS (a per-tier
# directory shared across that tier's tasks, so a replaced task hands off
# its retries to a sibling - see
# docs/0.9.x/smtp-out-queue-persistence-plan.md for the pattern). The
# access point's creation_info sets root:mail mode 0700 on first
# creation, but a stale directory from a previous deploy or operator
# action could still drift; re-assert the rpm default ownership and mode
# immediately before exec. No-op on subsequent boots when ownership
# already matches. Best-effort by design (|| true): smtp-in runs without
# CAP_CHOWN, so its chown succeeds only as the no-op (the kernel skips
# the capability check when the owner is unchanged) - real ownership
# drift there surfaces as sendmail queue-permission errors rather than
# being silently repaired.
if [ "${TIER:-}" = "smtp-out" ] || [ "${TIER:-}" = "smtp-in" ]; then
  chown root:mail /var/spool/mqueue 2>/dev/null || true
  chmod 0700 /var/spool/mqueue 2>/dev/null || true
fi

exec /usr/sbin/sendmail -bD -q15m
