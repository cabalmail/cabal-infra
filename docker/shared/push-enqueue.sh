#!/bin/bash
# Spools a push-notification wake signal for one delivered message.
#
# Invoked by the :0c procmail recipe in docker/imap/configs/procmailrc with
# the message on stdin: push-enqueue.sh <user> <folder>. Writes one JSON file
# {user, folder, uid, msg_id} into /var/spool/cabal-push; the companion
# push-spool-drain.sh daemon (supervisord, root) forwards spool files to the
# cabal-push-queue SQS queue with the task-role credentials from its own
# environment. Splitting spool from send keeps this delivery-path hook fast
# and credential-free: procmail's children run as the recipient user with a
# sendmail-sanitized environment, and handing them AWS credentials would
# regress the container-hardening posture for a best-effort side effect.
# See docs/0.11.x/push-notifications.md.
#
# Best-effort BY CONTRACT: this script must never fail (or slow) mail
# delivery, so it deviates from the house `set -e` rule — every failure path
# logs to stderr (procmail appends child stderr to its own $LOGFILE) and
# exits 0.
set -uo pipefail

SPOOL_DIR=/var/spool/cabal-push
# A spool this deep means the drain daemon has been failing for a long time;
# newer signals would age out of relevance before ever sending. Shed instead.
MAX_SPOOL_FILES=1000

log() {
  echo "[push-enqueue] $*" >&2
}

drain_stdin() {
  # Always swallow the rest of the message so procmail's writer never sees
  # SIGPIPE on the carbon-copy pipe.
  cat > /dev/null 2>&1 || true
}

user="${1:-}"
folder="${2:-INBOX}"
if [ -z "$user" ] || [ ! -d "$SPOOL_DIR" ]; then
  # Missing spool dir = push not provisioned on this tier/image; not an error.
  drain_stdin
  exit 0
fi

# First Message-ID header value, unfolded (RFC 5322 allows the value on a
# continuation line, which Exchange commonly does), angle brackets included.
msg_id=$(awk '
  /^$/ { exit }
  tolower($0) ~ /^message-id:/ { grab = 1; value = $0; next }
  grab && /^[ \t]/ { value = value $0; next }
  grab { exit }
  END {
    if (match(value, /<[^>]*>/)) {
      print substr(value, RSTART, RLENGTH)
    }
  }
')
drain_stdin

# Dovecot's next-uid for the mailbox ("3 V<validity> N<next-uid> ..."); the
# message being delivered will get this UID when Dovecot next scans the
# Maildir, unless another delivery races us — hence hint, not truth. The
# consumer side resolves by Message-ID.
home_dir=$(getent passwd "$user" | cut -d: -f6)
uid_hint=0
if [ -n "$home_dir" ] && [ -r "$home_dir/Maildir/dovecot-uidlist" ]; then
  uid_hint=$(head -n 1 "$home_dir/Maildir/dovecot-uidlist" \
    | tr ' ' '\n' | sed -n 's/^N\([0-9]*\)$/\1/p')
  uid_hint="${uid_hint:-0}"
fi

count=$(find "$SPOOL_DIR" -maxdepth 1 -name 'sig.*' 2>/dev/null | wc -l)
if [ "$count" -ge "$MAX_SPOOL_FILES" ]; then
  log "spool full ($count files); dropping signal for $user"
  exit 0
fi

body=$(jq -cn \
  --arg user "$user" \
  --arg folder "$folder" \
  --arg msg_id "$msg_id" \
  --argjson uid "$uid_hint" \
  '{user: $user, folder: $folder, uid: $uid, msg_id: $msg_id}') || {
  log "failed to build signal body for $user"
  exit 0
}

# Write-then-rename so the drain daemon never reads a partial file. The
# daemon authenticates the signal by comparing the file's owner to its
# `user` field, so the file must be created by this (recipient) uid.
tmp=$(mktemp "$SPOOL_DIR/.tmp.XXXXXXXX" 2>/dev/null) || {
  log "cannot write to spool for $user"
  exit 0
}
if printf '%s\n' "$body" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$SPOOL_DIR/sig.${tmp##*/.tmp.}" 2>/dev/null; then
  exit 0
fi
log "failed to spool signal for $user"
rm -f "$tmp" 2>/dev/null
exit 0
