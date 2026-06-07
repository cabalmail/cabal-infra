#!/usr/bin/env bash
#
# Clears the IMAP planned-maintenance flag once Dovecot is serving, then idles.
#
# CI sets /cabal/maintenance/imap = {"active": true, ...} just before it
# triggers an IMAP image roll (see .github/scripts/maintenance-flag.sh). Because
# the IMAP service runs a single task, the old container stops before this new
# one starts, so this container IS the signal that IMAP is back. Once Dovecot is
# accepting connections we flip the flag to {"active": false} and the IMAP-backed
# Lambdas resume serving instead of returning the maintenance 503.
#
# Run as a supervisord daemon (imap image only). After clearing, it execs into a
# no-op wait so it stays RUNNING - the imap HEALTHCHECK flags any program that is
# not RUNNING, so a one-shot that EXITed would mark the container unhealthy.
#
# Fail-soft by design: a failed readiness wait or a failed SSM write only logs a
# warning and idles. Failing to clear the flag must NEVER crash-loop the IMAP
# container - the `until` epoch CI wrote is a backstop that expires the flag on
# its own, so the worst case is a few extra minutes of "maintenance" copy.

set -euo pipefail

PARAM="/cabal/maintenance/imap"
READY_HOST="127.0.0.1"
READY_PORT="143"
READY_TIMEOUT="${MAINTENANCE_READY_TIMEOUT:-180}"

log() { echo "[clear-maintenance] $*"; }

# True when a TCP connection to local Dovecot succeeds. Uses bash /dev/tcp so we
# don't depend on nc/ss being installed; the subshell closes the fd immediately.
dovecot_ready() {
  (exec 3<>"/dev/tcp/${READY_HOST}/${READY_PORT}") 2>/dev/null
}

# Stay RUNNING forever so supervisord's status stays green. Only CI sets the
# flag, and that happens before this container exists, so there is nothing left
# to do once it has been cleared once.
idle() {
  log "idle"
  exec tail -f /dev/null
}

main() {
  log "waiting up to ${READY_TIMEOUT}s for Dovecot on ${READY_HOST}:${READY_PORT}..."
  waited=0
  while ! dovecot_ready; do
    if [ "${waited}" -ge "${READY_TIMEOUT}" ]; then
      log "WARN Dovecot not ready after ${READY_TIMEOUT}s; leaving flag for the TTL backstop"
      idle
    fi
    sleep 2
    waited=$((waited + 2))
  done

  log "Dovecot is accepting connections; clearing maintenance flag"
  if aws ssm put-parameter \
       --name "${PARAM}" \
       --type String \
       --overwrite \
       --value '{"active":false}' >/dev/null 2>&1; then
    log "maintenance flag cleared"
  else
    log "WARN could not clear maintenance flag (the TTL backstop will expire it)"
  fi

  idle
}

case "${1:-daemon}" in
  daemon) main ;;
  *) log "usage: clear-maintenance.sh daemon"; exit 2 ;;
esac
