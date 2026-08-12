#!/bin/bash
# Rebuilds /etc/aliases from the static system aliases baked into the
# image plus the dynamic multi-user aliases generate-config.sh writes to
# /etc/aliases.dynamic, then recompiles the alias database.
#
# IMAP tier only: /etc/aliases.static is COPYed into the imap image alone
# and /etc/aliases.dynamic is written only for tier=imap. Both callers
# (prepare-sendmail.sh at startup, reconfigure.sh on every regeneration)
# already guard on TIER = imap.
#
# Deliberately silent: the callers own their own [component] logging, and
# newaliases prints its own summary.
set -euo pipefail

cat /etc/aliases.static > /etc/aliases
if [ -f /etc/aliases.dynamic ]; then
  echo "" >> /etc/aliases
  echo "# Dynamic aliases (generated from DynamoDB)" >> /etc/aliases
  cat /etc/aliases.dynamic >> /etc/aliases
fi
newaliases
