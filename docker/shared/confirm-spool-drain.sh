#!/bin/bash
# Clears the `pending` flag for spooled address-confirmation signals (imap).
#
# The delivery-path half (confirm-cabal-address, run by procmail as the
# recipient user) only writes JSON files into /var/spool/cabal-confirm; this
# daemon — started by supervisord as root, so it inherits the container
# environment including the ECS task-role credential URI — performs the
# conditional DynamoDB UpdateItem that removes `pending`/`pending_since`
# from the cabal-addresses row and deletes the file. Splitting spool from
# write keeps AWS credentials away from the per-user delivery agents (the
# 0.10.x container-hardening posture), same as push-spool-drain.sh.
# docs/1.x/browser-extension-plan.md, Phase 3.1.d.
#
# The daemon does NOT publish a reconfigure event: the just-confirmed rule
# in /etc/procmail-pending.rc becomes a harmless no-op the moment the flag
# clears (the conditional update fails and the file is dropped as already
# confirmed), and the next address-change event or the periodic fallback
# regenerate removes the rule opportunistically.
#
# Env (from the task definition via supervisord):
#   ADDRESSES_TABLE_NAME  override for tests; defaults to cabal-addresses
#   AWS_REGION            required by the aws CLI
set -euo pipefail

SPOOL_DIR=/var/spool/cabal-confirm
POLL_SECONDS=5
# A confirmation older than the reaper's TTL floor is moot; shed it.
MAX_AGE_SECONDS=86400
TABLE_NAME="${ADDRESSES_TABLE_NAME:-cabal-addresses}"

echo "[confirm-spool-drain] Starting..."

mkdir -p "$SPOOL_DIR"
chmod 1777 "$SPOOL_DIR"

process_one() {
  local file="$1"

  # Age out stale signals (drain was down / DynamoDB unreachable for long).
  local now file_mtime
  now=$(date +%s)
  file_mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
  if [ $((now - file_mtime)) -gt "$MAX_AGE_SECONDS" ]; then
    echo "[confirm-spool-drain] dropping stale signal $(basename "$file")"
    rm -f "$file"
    return 0
  fi

  local owner address
  owner=$(stat -c %U "$file" 2>/dev/null || echo "")
  address=$(jq -re '.address // empty' "$file" 2>/dev/null) || {
    echo "[confirm-spool-drain] dropping malformed signal $(basename "$file")"
    rm -f "$file"
    return 0
  }
  # Same charset gate generate-config.sh applies before emitting a rule;
  # anything else never came from a generated recipe.
  if ! [[ "$address" =~ ^[a-zA-Z0-9._%+=-]+@[a-zA-Z0-9.-]+$ ]]; then
    echo "[confirm-spool-drain] dropping signal with unsafe address" \
         "$(basename "$file")"
    rm -f "$file"
    return 0
  fi

  # Authenticity: the spool is world-writable (sticky), so any local user
  # could drop a file naming any address. A legitimate signal was spooled by
  # procmail running as the recipient, so the file's owner must be among the
  # address row's slash-delimited assignees (or root, if a signal was ever
  # spooled before DROPPRIVS). The row read also tells us whether there is
  # anything left to do.
  local key row assignees
  key=$(jq -cn --arg a "$address" '{address: {S: $a}}')
  if ! row=$(aws dynamodb get-item \
      --table-name "$TABLE_NAME" \
      --key "$key" \
      --projection-expression '#u, #p' \
      --expression-attribute-names '{"#u": "user", "#p": "pending"}' \
      --region "${AWS_REGION:-us-east-1}" \
      --output json 2>/dev/null); then
    # Leave the file for the next pass: if DynamoDB is down, retrying the
    # rest of the spool right now only burns CPU.
    echo "[confirm-spool-drain] lookup failed for $address; will retry"
    return 1
  fi
  if [ "$(jq -r '.Item.pending.BOOL // false' <<<"$row")" != "true" ]; then
    # Row gone (reaped/revoked) or already confirmed; nothing to do.
    rm -f "$file"
    return 0
  fi
  assignees=$(jq -r '.Item.user.S // ""' <<<"$row")
  if [ "$owner" != "root" ] \
      && ! grep -qxF "$owner" <<<"${assignees//\//$'\n'}"; then
    echo "[confirm-spool-drain] dropping spoofed signal $(basename "$file"):" \
         "owner=$owner address=$address"
    rm -f "$file"
    return 0
  fi

  local err
  if err=$(aws dynamodb update-item \
      --table-name "$TABLE_NAME" \
      --key "$key" \
      --update-expression 'REMOVE #p, pending_since' \
      --condition-expression '#p = :true' \
      --expression-attribute-names '{"#p": "pending"}' \
      --expression-attribute-values '{":true": {"BOOL": true}}' \
      --region "${AWS_REGION:-us-east-1}" 2>&1 >/dev/null); then
    echo "[confirm-spool-drain] confirmed $address"
    rm -f "$file"
    return 0
  fi
  if grep -q 'ConditionalCheckFailedException' <<<"$err"; then
    # /confirm_address or the reaper won the race; that is a success.
    rm -f "$file"
    return 0
  fi
  echo "[confirm-spool-drain] update failed for $address; will retry: $err"
  return 1
}

echo "[confirm-spool-drain] Draining $SPOOL_DIR to $TABLE_NAME"
while true; do
  for file in "$SPOOL_DIR"/sig.*; do
    [ -e "$file" ] || continue
    process_one "$file" || break
  done
  sleep "$POLL_SECONDS"
done
