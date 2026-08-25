#!/bin/bash
# Forwards the message on stdin to the given addresses, stamped with an
# X-Loop marker.
#
# Usage: cabal-rules-forward.sh <user> <address>...
#
# Emitted by compile-user-rules.py for rules with the Forward auxiliary
# action (docs/1.x/user-mail-rules-plan.md, Phase 2b; issue #1266). The
# compiled recipe's condition skips any message already carrying this
# user's marker, and this script adds the marker to the outbound copy - so
# a forward that routes back into the same mailbox (self-forward, alias
# cycles) is forwarded exactly once instead of ping-ponging until
# sendmail's hop limit. The formail|sendmail pipeline lives in here because
# the system procmailrc sets SHELL=/usr/bin/false: compiled recipes may
# only exec fixed-path helpers, never inline shell pipelines.
#
# Addresses are validated by the compiler (shape-checked, control-free,
# cannot start with '-'); the `--` is defense in depth.
set -euo pipefail

user="${1:?user required}"
shift
if [ "$#" -lt 1 ]; then
  echo "[cabal-rules-forward] no addresses" >&2
  exit 64
fi

/usr/bin/formail -A "X-Loop: cabal-rules-${user}" \
  | /usr/sbin/sendmail -oi -- "$@"
