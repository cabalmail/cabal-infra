#!/bin/bash
# Spools the message on stdin for forwarding to the given addresses,
# stamped with an X-Loop marker.
#
# Usage: cabal-rules-forward.sh <user> <address>...
#
# Emitted by compile-user-rules.py for rules with the Forward auxiliary
# action (docs/1.x/user-mail-rules-plan.md, Phase 2b; issue #1266). The
# compiled recipe's condition skips any message already carrying this
# user's marker, and this script adds the marker to the spooled copy - so
# a forward that routes back into the same mailbox is forwarded exactly
# once instead of ping-ponging until sendmail's hop limit.
#
# Spool-then-drain, mirroring push-enqueue.sh: under DROPPRIVS this runs
# as the recipient, and unprivileged sendmail client submission is
# unavailable in the hardened task ("Program mode requires special
# privileges"), so the privileged submission happens in the
# cabal-forward-drain.sh supervisord daemon (root). One file per forward
# in /var/spool/cabal-forward: line 1 is JSON metadata
# {user, sender, addrs}, the rest is the stamped RFC 5322 message. The
# drain authenticates each file by owner, so this (recipient) uid must
# create it. Unlike push-enqueue this is NOT best-effort: forward is a
# primary rule action, so failures exit non-zero and procmail's `w` flag
# records a program failure in the user's procmail log.
set -euo pipefail

SPOOL_DIR=/var/spool/cabal-forward
# Far beyond any sane backlog; if the drain has been failing this long,
# shedding beats spooling forever (matches the push spool posture).
MAX_SPOOL_FILES=500

user="${1:?user required}"
shift
if [ "$#" -lt 1 ]; then
  echo "[cabal-rules-forward] no addresses" >&2
  exit 64
fi
if [ ! -d "$SPOOL_DIR" ]; then
  echo "[cabal-rules-forward] spool missing: $SPOOL_DIR" >&2
  exit 64
fi
count=$(find "$SPOOL_DIR" -maxdepth 1 -name 'fwd.*' 2>/dev/null | wc -l)
if [ "$count" -ge "$MAX_SPOOL_FILES" ]; then
  echo "[cabal-rules-forward] spool full ($count files)" >&2
  exit 75
fi

work=$(mktemp)
trap 'rm -f "$work"' EXIT
cat > "$work"

# Original envelope sender from the mbox From_ line procmail feeds pipes
# (preserved on the outbound copy so bounces return to the origin, the
# same envelope procmail's own `!` action would have used). Absent line =
# empty sender; the drain falls back to the null-ish default.
sender=""
if head -n 1 "$work" | grep -q '^From '; then
  sender=$(head -n 1 "$work" | awk '{print $2}')
fi

tmp=$(mktemp "$SPOOL_DIR/.tmp.XXXXXXXX")
trap 'rm -f "$work" "$tmp"' EXIT
{
  jq -cn --arg user "$user" --arg sender "$sender" \
    '{user: $user, sender: $sender, addrs: $ARGS.positional}' --args "$@"
  # -I "From " (no colon) strips the mbox From_ line - submissions are
  # pure RFC 5322 - and formail must do it itself, or it would
  # regenerate a synthetic one; -A stamps the loop marker.
  /usr/bin/formail -I "From " -A "X-Loop: cabal-rules-${user}" < "$work"
} > "$tmp"
mv "$tmp" "$SPOOL_DIR/fwd.${tmp##*/.tmp.}"
trap 'rm -f "$work"' EXIT
