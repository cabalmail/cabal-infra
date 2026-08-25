#!/bin/bash
# Submits spooled user-rule forwards via sendmail (imap tier).
#
# The delivery-path half (cabal-rules-forward.sh, run by procmail as the
# recipient under DROPPRIVS) only writes spool files into
# /var/spool/cabal-forward; this daemon - started by supervisord as root,
# where sendmail command-line submission is permitted - submits each one
# and deletes it. Splitting spool from send keeps privilege away from the
# per-user delivery agents (the same 0.10.x hardening posture as
# push-enqueue / push-spool-drain) and keeps sendmail latency out of the
# procmail hot path. docs/1.x/user-mail-rules-plan.md, Phase 2b.
#
# File format (written by cabal-rules-forward.sh): line 1 is JSON
# {user, sender, addrs}; the remainder is the X-Loop-stamped RFC 5322
# message. The spool is the trust boundary: every field is re-validated
# here, and the file must be OWNED by the user it names - under DROPPRIVS
# a legitimate file is always recipient-owned, so unlike the push drain
# there is no root-owner exception.
set -euo pipefail

SPOOL_DIR=/var/spool/cabal-forward
POLL_SECONDS=2
# Submission failures retry each pass until this age, then shed with a
# log line. (Post-submission retries are sendmail's queue's job; this
# window only covers the local submit step itself.)
MAX_AGE_SECONDS=21600
MAX_ADDRS=10
ADDR_RE='^[^[:space:]@-][^[:space:]@]*@[^[:space:]@]+\.[^[:space:]@]+$'
USER_RE='^[A-Za-z0-9._-]+$'

echo "[cabal-forward-drain] Starting..."
mkdir -p "$SPOOL_DIR"
chmod 1777 "$SPOOL_DIR"

send_one() {
  local file="$1"

  local now file_mtime
  now=$(date +%s)
  file_mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
  if [ $((now - file_mtime)) -gt "$MAX_AGE_SECONDS" ]; then
    echo "[cabal-forward-drain] dropping stale forward $(basename "$file")"
    rm -f "$file"
    return 0
  fi

  local owner meta claimed sender
  owner=$(stat -c %U "$file" 2>/dev/null || echo "")
  meta=$(head -n 1 "$file")
  claimed=$(jq -re '.user // empty' <<< "$meta" 2>/dev/null) || claimed=""
  if [ -z "$claimed" ] || ! [[ "$claimed" =~ $USER_RE ]] \
      || [ "$owner" != "$claimed" ]; then
    echo "[cabal-forward-drain] dropping spoofed/malformed forward" \
         "$(basename "$file"): owner=$owner claims=${claimed:-?}"
    rm -f "$file"
    return 0
  fi

  local -a addrs=()
  local addr
  while IFS= read -r addr; do
    if [ ${#addrs[@]} -ge "$MAX_ADDRS" ] || [ "${#addr}" -gt 320 ] \
        || ! [[ "$addr" =~ $ADDR_RE ]]; then
      echo "[cabal-forward-drain] dropping forward $(basename "$file"):" \
           "bad address"
      rm -f "$file"
      return 0
    fi
    addrs+=("$addr")
  done < <(jq -r '.addrs[]?' <<< "$meta" 2>/dev/null)
  if [ ${#addrs[@]} -eq 0 ]; then
    echo "[cabal-forward-drain] dropping forward $(basename "$file"): no addrs"
    rm -f "$file"
    return 0
  fi

  # Envelope sender: the original message's, when it parses as an
  # address; otherwise the null-ish local default so bounces terminate
  # here instead of backscattering.
  sender=$(jq -re '.sender // empty' <<< "$meta" 2>/dev/null) || sender=""
  if ! [[ "$sender" =~ $ADDR_RE ]] || [ "${#sender}" -gt 320 ]; then
    sender="mailer-daemon"
  fi

  if tail -n +2 "$file" \
      | /usr/sbin/sendmail -oi -f "$sender" -- "${addrs[@]}"; then
    echo "[cabal-forward-drain] forwarded for $claimed:" \
         "$(basename "$file") -> ${#addrs[@]} rcpt"
    rm -f "$file"
    return 0
  fi
  echo "[cabal-forward-drain] submit failed for $(basename "$file"); will retry"
  return 1
}

echo "[cabal-forward-drain] Draining $SPOOL_DIR"
while true; do
  for file in "$SPOOL_DIR"/fwd.*; do
    [ -e "$file" ] || continue
    send_one "$file" || break
  done
  sleep "$POLL_SECONDS"
done
