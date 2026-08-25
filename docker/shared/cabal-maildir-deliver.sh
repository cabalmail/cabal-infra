#!/bin/bash
# Delivers the message on stdin into a Maildir with initial info flags.
#
# Usage: cabal-maildir-deliver.sh <maildir-path> <flags>
#
# Emitted by compile-user-rules.py for rules with the Flag / Mark-read
# auxiliary actions (docs/1.x/user-mail-rules-plan.md, Phase 2b). Procmail's
# native maildir delivery writes to new/ with no info suffix, so pre-flagged
# delivery follows the maildir spec by hand: write tmp/, rename into cur/
# with the :2,<flags> suffix (flags pre-sorted by the compiler; F=Flagged,
# S=Seen). Runs as the recipient from a compiled recipe; procmail's `w` flag
# reads our exit status, so any failure leaves the message undelivered for
# procmail's later recipes / DEFAULT instead of losing it.
#
# Arguments arrive from the compiler, not from user input (the folder path
# is resolved against the safe character set and the live Maildir at compile
# time) - the checks here are defense in depth, not the primary validation.
set -euo pipefail

maildir="${1:?maildir path required}"
flags="${2:?flags required}"

case "$flags" in
  F|S|FS) ;;
  *) echo "[cabal-maildir-deliver] invalid flags: $flags" >&2; exit 64 ;;
esac
if [ ! -d "$maildir/tmp" ] || [ ! -d "$maildir/cur" ]; then
  echo "[cabal-maildir-deliver] not a maildir: $maildir" >&2
  exit 64
fi

# Unique per the maildir naming rules: seconds.<pid+random>.<host>. The
# rename is atomic on the same filesystem, so readers never see a partial
# message.
name="$(date +%s).P$$R${RANDOM}.$(hostname)"
tmp="$maildir/tmp/$name"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"
mv "$tmp" "$maildir/cur/${name}:2,${flags}"
trap - EXIT
