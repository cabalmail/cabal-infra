#!/bin/bash
# Enqueues a push-notification wake signal for one delivered message.
#
# Invoked by the :0c procmail recipe in docker/imap/configs/procmailrc with
# the message on stdin: push-enqueue.sh <user> <folder>. Sends one JSON line
# {user, folder, uid, msg_id} to the cabal-push-queue SQS queue; the
# push_dispatch Lambda fans it out to APNs (docs/0.11.0/push-notifications.md).
#
# Best-effort BY CONTRACT: this script must never fail (or slow) mail
# delivery, so it deviates from the house `set -e` rule — every failure path
# logs to stderr (procmail appends child stderr to its own $LOGFILE) and
# exits 0. The UID is a hint: procmail runs before Dovecot assigns one, so we
# pass Dovecot's next-uid and the consumer side resolves by Message-ID.
#
# Env comes from /etc/cabal-push-enqueue.env (written by entrypoint.sh):
# sendmail sanitizes its delivery agents' environment, so the ECS task-role
# credential URI and queue URL never survive into procmail's children.
set -uo pipefail

log() {
  echo "[push-enqueue] $*" >&2
}

drain() {
  # Always swallow the rest of the message so procmail's writer never sees
  # SIGPIPE on the carbon-copy pipe.
  cat > /dev/null 2>&1 || true
}

if [ ! -r /etc/cabal-push-enqueue.env ]; then
  # Not an error: environments predating the PUSH_QUEUE_URL task definition
  # (or with push disabled) simply have no env file.
  drain
  exit 0
fi
# shellcheck source=/dev/null
. /etc/cabal-push-enqueue.env

user="${1:-}"
folder="${2:-INBOX}"
if [ -z "$user" ] || [ -z "${PUSH_QUEUE_URL:-}" ]; then
  log "skipping: user or PUSH_QUEUE_URL missing"
  drain
  exit 0
fi

# First Message-ID header before the body separator, angle brackets included.
msg_id=$(sed -n '/^$/q; s/^[Mm][Ee][Ss][Ss][Aa][Gg][Ee]-[Ii][Dd]:[[:space:]]*\(<[^>]*>\).*/\1/p' | head -n 1)
drain

# Dovecot's next-uid for the mailbox ("3 V<validity> N<next-uid> ..."); the
# message being delivered will get this UID when Dovecot next scans the
# Maildir, unless another delivery races us — hence hint, not truth.
home_dir=$(getent passwd "$user" | cut -d: -f6)
uid_hint=0
if [ -n "$home_dir" ] && [ -r "$home_dir/Maildir/dovecot-uidlist" ]; then
  uid_hint=$(head -n 1 "$home_dir/Maildir/dovecot-uidlist" \
    | tr ' ' '\n' | sed -n 's/^N\([0-9]*\)$/\1/p')
  uid_hint="${uid_hint:-0}"
fi

body=$(jq -cn \
  --arg user "$user" \
  --arg folder "$folder" \
  --arg msg_id "$msg_id" \
  --argjson uid "$uid_hint" \
  '{user: $user, folder: $folder, uid: $uid, msg_id: $msg_id}') || {
  log "failed to build message body for $user"
  exit 0
}

if ! aws sqs send-message \
    --queue-url "$PUSH_QUEUE_URL" \
    --message-body "$body" \
    --region "${AWS_REGION:-us-east-1}" \
    > /dev/null 2>&1; then
  log "enqueue failed for $user ($folder)"
fi
exit 0
