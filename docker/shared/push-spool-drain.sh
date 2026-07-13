#!/bin/bash
# Forwards spooled push wake signals to SQS (imap tier).
#
# The delivery-path half (push-enqueue.sh, run by procmail as the recipient
# user) only writes JSON files into /var/spool/cabal-push; this daemon —
# started by supervisord as root, so it inherits the container environment
# including the ECS task-role credential URI — sends each file to the
# cabal-push-queue SQS queue and deletes it. Splitting spool from send keeps
# AWS credentials away from the per-user delivery agents (the 0.10.x
# container-hardening posture) and keeps SQS latency and outages out of the
# procmail hot path entirely. See docs/0.11.0/push-notifications.md.
#
# Env (from the task definition via supervisord):
#   PUSH_QUEUE_URL  target queue; unset = push not provisioned, idle forever
#   AWS_REGION      required by the aws CLI
set -euo pipefail

SPOOL_DIR=/var/spool/cabal-push
POLL_SECONDS=2
# A wake signal loses its point long before the queue's 1h retention; shed
# anything the drain could not send for that long.
MAX_AGE_SECONDS=3600

echo "[push-spool-drain] Starting..."

if [ -z "${PUSH_QUEUE_URL:-}" ]; then
  # Idle RUNNING rather than exit: a one-shot exit would just be restarted
  # by supervisord's autorestart (same convention as clear-maintenance.sh).
  echo "[push-spool-drain] PUSH_QUEUE_URL not set; push disabled, idling."
  exec sleep infinity
fi

mkdir -p "$SPOOL_DIR"
chmod 1777 "$SPOOL_DIR"

send_one() {
  local file="$1"

  # Age out stale signals (drain was down / SQS unreachable for a long time).
  local now file_mtime
  now=$(date +%s)
  file_mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
  if [ $((now - file_mtime)) -gt "$MAX_AGE_SECONDS" ]; then
    echo "[push-spool-drain] dropping stale signal $(basename "$file")"
    rm -f "$file"
    return 0
  fi

  # Authenticity: the spool is world-writable (sticky), so any local user
  # could drop a file claiming to be someone else. The recipe runs as the
  # recipient, so a legitimate file is owned by the user it names (or by
  # root, when procmail processed /etc/procmailrc before dropping
  # privileges). Anything else is spoofed — delete it.
  local owner claimed
  owner=$(stat -c %U "$file" 2>/dev/null || echo "")
  claimed=$(jq -re '.user // empty' "$file" 2>/dev/null) || {
    echo "[push-spool-drain] dropping malformed signal $(basename "$file")"
    rm -f "$file"
    return 0
  }
  if [ "$owner" != "root" ] && [ "$owner" != "$claimed" ]; then
    echo "[push-spool-drain] dropping spoofed signal $(basename "$file"):" \
         "owner=$owner claims user=$claimed"
    rm -f "$file"
    return 0
  fi

  if aws sqs send-message \
      --queue-url "$PUSH_QUEUE_URL" \
      --message-body "$(cat "$file")" \
      --region "${AWS_REGION:-us-east-1}" \
      > /dev/null 2>&1; then
    rm -f "$file"
    return 0
  fi
  # Leave the file for the next pass and stop this pass: if SQS is down,
  # retrying the rest of the spool right now only burns CPU.
  echo "[push-spool-drain] send failed for $(basename "$file"); will retry"
  return 1
}

echo "[push-spool-drain] Draining $SPOOL_DIR to $PUSH_QUEUE_URL"
while true; do
  for file in "$SPOOL_DIR"/sig.*; do
    [ -e "$file" ] || continue
    send_one "$file" || break
  done
  sleep "$POLL_SECONDS"
done
