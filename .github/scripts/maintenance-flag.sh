#!/usr/bin/env bash
#
# Set or clear the IMAP planned-maintenance flag in SSM Parameter Store.
#
# The IMAP ECS service is hard-capped at one task (Dovecot has Maildir-over-EFS
# concurrency issues), so every IMAP image roll stops the old container before
# starting the new one - a true zero-task window. CI calls `set` just before it
# triggers that roll so the IMAP-backed Lambdas return a friendly 503 ("planned
# maintenance") instead of relaying a raw connection error. The flag is NOT
# cleared here: the deploy is fire-and-forget (deploy-ecs-service.sh returns as
# soon as it has triggered the roll, not when the roll finishes), so the new
# IMAP container clears it once Dovecot is serving (docker/shared/clear-
# maintenance.sh). The `until` epoch written by `set` is a backstop so a
# crashed/cancelled deploy job cannot wedge the flag on.
#
# `clear` is provided for manual operator use (e.g. stage verification); the
# normal deploy path never calls it.
#
# Usage:
#   maintenance-flag.sh set      # active=true, until=now+TTL
#   maintenance-flag.sh clear    # active=false
#
# Env overrides:
#   MAINTENANCE_TTL_SECONDS   backstop expiry, seconds (default 1200)
#   MAINTENANCE_RETRY_AFTER   Retry-After hint, seconds (default 30)
#   MAINTENANCE_MESSAGE       client-facing copy

set -euo pipefail

ACTION="${1:?usage: maintenance-flag.sh set|clear}"
PARAM="/cabal/maintenance/imap"
TTL_SECONDS="${MAINTENANCE_TTL_SECONDS:-1200}"
RETRY_AFTER="${MAINTENANCE_RETRY_AFTER:-30}"
MESSAGE="${MAINTENANCE_MESSAGE:-Email access is temporarily unavailable due to planned maintenance.}"

log() { echo "[maintenance-flag] $*"; }

case "${ACTION}" in
  set)
    until_epoch=$(( $(date +%s) + TTL_SECONDS ))
    value="$(jq -cn \
      --argjson until "${until_epoch}" \
      --argjson retry "${RETRY_AFTER}" \
      --arg msg "${MESSAGE}" \
      '{active: true, until: $until, retry_after: $retry, message: $msg}')"
    ;;
  clear)
    value='{"active":false}'
    ;;
  *)
    log "unknown action: ${ACTION} (expected set|clear)"
    exit 1
    ;;
esac

aws ssm put-parameter \
  --name "${PARAM}" \
  --type String \
  --overwrite \
  --value "${value}" >/dev/null

log "${ACTION}: ${PARAM} = ${value}"
