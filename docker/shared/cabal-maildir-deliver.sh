#!/bin/bash
# Delivers the message on stdin into a Maildir with initial info flags.
#
# Usage: cabal-maildir-deliver.sh <maildir-path> <flags> [<folder> <keywords>]
#
# Emitted by compile-user-rules.py for rules with the Flag / Mark-read
# auxiliary actions (docs/1.x/user-mail-rules-plan.md, Phase 2b). Procmail's
# native maildir delivery writes to new/ with no info suffix, so pre-flagged
# delivery follows the maildir spec by hand: write tmp/, rename into cur/
# with the :2,<flags> suffix (flags pre-sorted by the compiler; F=Flagged,
# S=Seen). An EMPTY flags argument is a plain delivery into new/ with no
# info suffix, exactly like native procmail - pending-decoration call sites
# (docs/1.x/rules-composition-and-custom-flags-plan.md, decision 3) build
# the argument from runtime variables, and an undecorated message must keep
# normal unread semantics. Runs as the recipient from a compiled recipe;
# procmail's `w` flag reads our exit status, so any failure leaves the
# message undelivered for procmail's later recipes / DEFAULT instead of
# losing it.
#
# KEYWORDED deliveries (decision 5 + its 2026-08-28 erratum): when the
# optional <keywords> argument (comma-separated cabal-flag-NN slot atoms)
# is non-empty, the raw write above is not safe - the keyword-letter
# mapping is Dovecot-owned - so the message is spooled for
# cabal-append-drain.py, the root daemon that performs the IMAP APPEND as
# the master user, and this script waits (bounded) for its response file.
# <folder> is then the IMAP folder name ('INBOX' for the root). Success
# means the drain delivered; anything else (rejection, timeout, drain
# down) exits non-zero so procmail falls through to later recipes /
# DEFAULT - an undecorated delivery, never a lost message.
#
# Arguments arrive from the compiler, not from user input (the folder path
# is resolved against the safe character set and the live Maildir at compile
# time) - the checks here are defense in depth, not the primary validation.
set -euo pipefail

SPOOL_DIR=/var/spool/cabal-append
WAIT_SECONDS=20

maildir="${1:?maildir path required}"
flags="${2?flags argument required (may be empty)}"
folder="${3:-}"
keywords="${4:-}"

case "$flags" in
  ""|F|S|FS) ;;
  *) echo "[cabal-maildir-deliver] invalid flags: $flags" >&2; exit 64 ;;
esac

if [ -n "$keywords" ]; then
  # ---- APPEND path: spool for the root drain and await its verdict ----
  if [ -z "$folder" ]; then
    echo "[cabal-maildir-deliver] keywords need a folder name" >&2
    exit 64
  fi
  case "$folder" in
    .*|*..*|*[!A-Za-z0-9._\ -]*)
      echo "[cabal-maildir-deliver] invalid folder: $folder" >&2; exit 64 ;;
  esac
  imap_flags=""
  IFS=',' read -ra atoms <<< "$keywords"
  for atom in "${atoms[@]}"; do
    case "$atom" in
      cabal-flag-0[1-9]|cabal-flag-1[0-9]|cabal-flag-20) ;;
      *) echo "[cabal-maildir-deliver] invalid keyword: $atom" >&2; exit 64 ;;
    esac
    imap_flags="$imap_flags,\"$atom\""
  done
  if [ "${flags#*F}" != "$flags" ]; then
    imap_flags="$imap_flags,\"\\\\Flagged\""
  fi
  if [ "${flags#*S}" != "$flags" ]; then
    imap_flags="$imap_flags,\"\\\\Seen\""
  fi
  imap_flags="[${imap_flags#,}]"

  nonce="$(date +%s).P$$R${RANDOM}"
  msg="$SPOOL_DIR/$nonce.msg"
  meta="$SPOOL_DIR/$nonce.json"
  resp="$SPOOL_DIR/$nonce.resp"
  cleanup() { rm -f "$msg" "$meta" "$SPOOL_DIR/.tmp.$nonce.json" "$resp"; }
  trap cleanup EXIT

  cat > "$msg"
  # The message half must exist before the JSON commits it; the drain only
  # acts on committed (renamed-into-place) .json files.
  printf '{"user":"%s","folder":"%s","flags":%s}\n' \
    "$LOGNAME" "$folder" "$imap_flags" > "$SPOOL_DIR/.tmp.$nonce.json"
  mv "$SPOOL_DIR/.tmp.$nonce.json" "$meta"

  waited=0
  while [ "$waited" -lt $((WAIT_SECONDS * 5)) ]; do
    if [ -f "$resp" ]; then
      verdict="$(cat "$resp" 2>/dev/null || echo fail)"
      if [ "$verdict" = "ok" ]; then
        trap - EXIT
        rm -f "$resp"
        exit 0
      fi
      echo "[cabal-maildir-deliver] append drain refused $nonce" >&2
      exit 75
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  echo "[cabal-maildir-deliver] append drain timed out for $nonce" >&2
  exit 75
fi

# ---- raw-write path: mapping-free system flags only ----
if [ ! -d "$maildir/tmp" ] || [ ! -d "$maildir/cur" ] || [ ! -d "$maildir/new" ]; then
  echo "[cabal-maildir-deliver] not a maildir: $maildir" >&2
  exit 64
fi

# Unique per the maildir naming rules: seconds.<pid+random>.<host>.
# `uname -n`, not `hostname`: the AL2023 runtime image does not ship the
# hostname binary. The rename is atomic on the same filesystem, so
# readers never see a partial message.
name="$(date +%s).P$$R${RANDOM}.$(uname -n)"
tmp="$maildir/tmp/$name"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"
if [ -z "$flags" ]; then
  mv "$tmp" "$maildir/new/$name"
else
  mv "$tmp" "$maildir/cur/${name}:2,${flags}"
fi
trap - EXIT
