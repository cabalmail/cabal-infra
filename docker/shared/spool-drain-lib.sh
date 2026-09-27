#!/bin/bash
# Shared skeleton for the spool/drain daemons (imap tier).
#
# push-spool-drain.sh, confirm-spool-drain.sh and cabal-forward-drain.sh are
# the root-side halves of three spool/drain splits: a delivery-path helper
# running as the recipient writes a file into a world-writable spool, and a
# supervisord-started daemon with the container's privileges (task-role
# credentials, sendmail submission) acts on it. Each daemon owns its own
# authenticity checks and its own action; what all three share is the spool
# directory's permissions, the stale-file shed and the polling loop.
#
# Sourced, not executed - the helpers run in the caller's shell, so the
# caller's `set -euo pipefail` applies and drain_poll_forever can call a
# handler the caller defined. Callers pass their own [component] tag so the
# log lines stay exactly what each daemon has always printed.

# Create spool directory $1 world-writable with the sticky bit, so the
# unprivileged delivery-path half can add files but only remove its own.
drain_init_spool() {
  mkdir -p "$1"
  chmod 1777 "$1"
}

# Shed file $2 when it is older than $3 seconds, logging under tag $1 with
# noun $4. Returns 0 only when it dropped the file, so callers spell the
# shed as `if drain_shed_if_stale ...; then return 0; fi` - an `if`
# condition, where a non-zero return is exempt from errexit.
drain_shed_if_stale() {
  local tag="$1" file="$2" max_age="$3" noun="$4"
  local now file_mtime
  now=$(date +%s)
  file_mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
  if [ $((now - file_mtime)) -gt "$max_age" ]; then
    echo "[$tag] dropping stale $noun $(basename "$file")"
    rm -f "$file"
    return 0
  fi
  return 1
}

# Poll directory $1 for files matching glob $2 forever, handing each to
# handler function $4 and sleeping $3 seconds between passes. A handler
# that returns non-zero means "could not act, leave the file" and ends the
# pass early: if the backend is down, working the rest of the spool now
# only burns CPU.
drain_poll_forever() {
  local dir="$1" glob="$2" poll_seconds="$3" handler="$4"
  local file
  while true; do
    # shellcheck disable=SC2231  # unquoted on purpose: $glob must expand
    for file in "$dir"/$glob; do
      [ -e "$file" ] || continue
      "$handler" "$file" || break
    done
    sleep "$poll_seconds"
  done
}
