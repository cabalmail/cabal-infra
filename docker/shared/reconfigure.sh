#!/bin/bash
# Live-reconfiguration sidecar — watches for address change signals
# via SQS and regenerates sendmail maps without restarting the container.
#
# Replaces: SSM SendCommand -> chef-solo full run
#
# This handles address changes only (the common case). User sync runs
# at container startup and does not need to happen on every address
# change. See Phase 5 for the rare new-user case.
#
# Required env vars: TIER, CERT_DOMAIN, AWS_REGION
# Optional env vars: SQS_QUEUE_URL (if unset, periodic-only mode)
#                    RECONFIGURE_INTERVAL (default: 900 = 15 minutes)
set -euo pipefail

QUEUE_URL="${SQS_QUEUE_URL:-}"
FALLBACK_INTERVAL="${RECONFIGURE_INTERVAL:-900}"

echo "[reconfigure] Starting config watch loop (tier: $TIER)"

if [ -n "$QUEUE_URL" ]; then
  echo "[reconfigure] SQS mode: polling $QUEUE_URL"
else
  echo "[reconfigure] WARNING: SQS_QUEUE_URL not set, running in periodic-only mode"
fi

# ── Regeneration function ──────────────────────────────────────
# Re-runs generate-config.sh (DynamoDB scan), rebuilds the hash
# databases sendmail reads, and signals daemons to reload.
regenerate() {
  echo "[reconfigure] Regenerating configs from DynamoDB..."
  /usr/local/bin/generate-config.sh

  # Rebuild sendmail hash databases (tier-specific).
  # Only the map files that exist for this tier need rebuilding.
  # Flat files (relay-domains, masq-domains, local-host-names) are
  # read directly by sendmail and don't need makemap.
  if [ "$TIER" = "imap" ]; then
    makemap hash /etc/mail/access       < /etc/mail/access
    makemap hash /etc/mail/virtusertable < /etc/mail/virtusertable
    # Reassemble aliases (static + dynamic) and rebuild the alias db
    cat /etc/aliases.static > /etc/aliases
    if [ -f /etc/aliases.dynamic ]; then
      echo "" >> /etc/aliases
      echo "# Dynamic aliases (generated from DynamoDB)" >> /etc/aliases
      cat /etc/aliases.dynamic >> /etc/aliases
    fi
    newaliases

  elif [ "$TIER" = "smtp-in" ]; then
    makemap hash /etc/mail/access       < /etc/mail/access
    makemap hash /etc/mail/mailertable  < /etc/mail/mailertable
    makemap hash /etc/mail/virtusertable < /etc/mail/virtusertable

  elif [ "$TIER" = "smtp-out" ]; then
    makemap hash /etc/mail/mailertable  < /etc/mail/mailertable
  fi

  # Signal sendmail to re-read .db map files (no restart needed)
  pkill -HUP sendmail || true

  # For SMTP-OUT, also reload OpenDKIM tables
  if [ "$TIER" = "smtp-out" ]; then
    pkill -HUP opendkim || true
  fi

  LAST_REGEN=$(date +%s)
  echo "[reconfigure] Done."
}

# ── Drain remaining SQS messages after a regeneration ──────────
# If several addresses were created in quick succession, we already
# picked up all changes from DynamoDB in one scan. Delete the
# remaining messages so we don't do redundant regenerations.
drain_queue() {
  while true; do
    DRAIN_MSG=$(aws sqs receive-message \
      --queue-url "$QUEUE_URL" \
      --wait-time-seconds 0 \
      --max-number-of-messages 10 \
      --region "$AWS_REGION" 2>/dev/null || echo "{}")

    HANDLES=$(echo "$DRAIN_MSG" | jq -r '.Messages[]?.ReceiptHandle // empty')
    if [ -z "$HANDLES" ]; then
      break
    fi

    echo "$HANDLES" | while read -r handle; do
      aws sqs delete-message \
        --queue-url "$QUEUE_URL" \
        --receipt-handle "$handle" \
        --region "$AWS_REGION" 2>/dev/null || true
    done
    echo "[reconfigure] Drained stale SQS messages."
  done
}

# ── Main loop ──────────────────────────────────────────────────
# Skip immediate regeneration — entrypoint.sh already ran
# generate-config.sh at startup.
LAST_REGEN=$(date +%s)

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - LAST_REGEN))

  if [ -n "$QUEUE_URL" ]; then
    # ── SQS mode: long-poll for 20 seconds ───────────────────
    # 20s long-poll is free (no API cost when idle) and gives
    # sub-second response when a message arrives.
    MSG=$(aws sqs receive-message \
      --queue-url "$QUEUE_URL" \
      --wait-time-seconds 20 \
      --max-number-of-messages 1 \
      --region "$AWS_REGION" \
      2>/dev/null || echo "{}")

    RECEIPT=$(echo "$MSG" | jq -r '.Messages[0].ReceiptHandle // empty')

    if [ -n "$RECEIPT" ]; then
      echo "[reconfigure] SQS message received, triggering regeneration..."
      # Delete the triggering message before regenerating so the
      # visibility timeout doesn't expire during a slow DynamoDB scan.
      aws sqs delete-message \
        --queue-url "$QUEUE_URL" \
        --receipt-handle "$RECEIPT" \
        --region "$AWS_REGION" 2>/dev/null || true

      regenerate
      drain_queue
      continue
    fi

    # Periodic fallback — safety net for lost SQS messages
    if [ "$ELAPSED" -ge "$FALLBACK_INTERVAL" ]; then
      echo "[reconfigure] Periodic fallback regeneration (every ${FALLBACK_INTERVAL}s)..."
      regenerate
    fi
  else
    # ── Periodic-only mode (no SQS queue configured) ─────────
    if [ "$ELAPSED" -ge "$FALLBACK_INTERVAL" ]; then
      echo "[reconfigure] Periodic regeneration (every ${FALLBACK_INTERVAL}s)..."
      regenerate
    fi
    sleep 60
  fi
done
