#!/bin/bash
# Backfill the \Answered flag from Sent-folder threading headers.
#
# Every reply sent through Cabalmail leaves a verbatim copy in the Sent
# mailbox whose In-Reply-To header names the Message-ID of the message
# being replied to. Until 2026-08 no client set \Answered on those
# originals, so the clients' "replied" indicators have nothing to show
# for historical replies. This one-shot joins the two sides:
#
#   1. collect every Message-ID named by an In-Reply-To header in Sent,
#   2. search the whole account for not-yet-\Answered messages carrying
#      one of those Message-IDs,
#   3. add \Answered to the matches.
#
# Idempotent: the search excludes already-answered messages and STORE
# +FLAGS never removes anything, so re-running is safe.
#
# Run INSIDE the imap container (needs doveadm and the mounted mailstore):
#   backfill-answered.sh                 # dry-run, every mail user
#   backfill-answered.sh alice bob       # dry-run, listed users only
#   backfill-answered.sh --apply alice   # actually write the flags
#
# Coverage is bounded by the evidence: replies whose Sent copy was
# deleted, or that were sent from outside Cabalmail, leave no trace and
# their originals stay unflagged. Only In-Reply-To is consulted — no
# References fallback — so a forward (which carries no In-Reply-To from
# either first-party composer) can never mark its original as answered.

set -euo pipefail

APPLY=0
USERS=()
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -*)
      echo "[backfill-answered] Unknown option: $arg" >&2
      echo "usage: backfill-answered.sh [--apply] [user ...]" >&2
      exit 2
      ;;
    *) USERS+=("$arg") ;;
  esac
done

if ! command -v doveadm >/dev/null 2>&1; then
  echo "[backfill-answered] doveadm not found — run inside the imap container" >&2
  exit 1
fi

if [ "${#USERS[@]}" -eq 0 ]; then
  # Mail users are the passwd entries sync-users.sh creates from the
  # Cognito pool: a /home/<user> home holding a Maildir. Filtering on
  # that shape skips system accounts without hard-coding a UID range.
  while IFS=: read -r name _ _ _ _ home _; do
    if [[ "$home" == /home/* && -d "$home/Maildir" ]]; then
      USERS+=("$name")
    fi
  done < <(getent passwd)
fi

if [ "${#USERS[@]}" -eq 0 ]; then
  echo "[backfill-answered] No mail users found" >&2
  exit 1
fi

MODE=dry-run
if [ "$APPLY" -eq 1 ]; then
  MODE=apply
fi
echo "[backfill-answered] Mode: $MODE; users: ${#USERS[@]}"

total_flagged=0
for user in "${USERS[@]}"; do
  if ! doveadm mailbox list -u "$user" | grep -qx Sent; then
    echo "[backfill-answered] $user: no Sent mailbox, skipping"
    continue
  fi

  # The set of Message-IDs the user has replied to. grep exits 1 when a
  # user's Sent folder holds no reply at all; that's a normal outcome,
  # not an error.
  ids=$(doveadm fetch -u "$user" hdr.in-reply-to mailbox Sent ALL \
    | grep -o '<[^>]*>' | sort -u || true)
  if [ -z "$ids" ]; then
    echo "[backfill-answered] $user: no replies in Sent"
    continue
  fi

  # One account-wide fetch (a doveadm query without a mailbox term spans
  # every mailbox) of the three fields the join needs. UNANSWERED keeps
  # already-flagged messages out, which is what makes re-runs no-ops.
  # The join emits "mailbox<TAB>uid" per hit; a folded Message-ID header
  # continues on indented lines, so those stay in scope until the next
  # field line.
  # Space-separated for awk -v: a Message-ID can't contain whitespace,
  # and BSD awk rejects newlines in -v strings (keeps the script testable
  # on macOS even though production is the container's gawk).
  ids_flat=$(tr '\n' ' ' <<<"$ids")
  matches=$(doveadm fetch -u "$user" 'mailbox uid hdr.message-id' UNANSWERED \
    | awk -v ids="$ids_flat" '
        BEGIN { n = split(ids, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        /^mailbox: /         { box = substr($0, 10); inmid = 0 }
        /^uid: /             { uid = substr($0, 6); inmid = 0 }
        /^hdr\.message-id:/  { inmid = 1 }
        /^[ \t]/             { }  # header continuation: leave inmid as-is
        /^[^ \t]/ && !/^(mailbox|uid|hdr\.message-id):/ { inmid = 0 }
        inmid && match($0, /<[^>]*>/) && (substr($0, RSTART, RLENGTH) in want) {
          print box "\t" uid
          inmid = 0
        }' || true)

  id_count=$(wc -l <<<"$ids" | tr -d ' ')
  if [ -z "$matches" ]; then
    echo "[backfill-answered] $user: $id_count replied-to ids, 0 unflagged matches"
    continue
  fi

  while IFS= read -r box; do
    uids=$(awk -F'\t' -v b="$box" '$1 == b { print $2 }' <<<"$matches")
    count=$(wc -l <<<"$uids" | tr -d ' ')
    if [ "$APPLY" -eq 1 ]; then
      # 500 UIDs per STORE, matching the Lambda helper's per-command cap.
      xargs -n 500 <<<"$uids" | while IFS= read -r chunk; do
        doveadm flags add -u "$user" '\Answered' mailbox "$box" uid "${chunk// /,}"
      done
      echo "[backfill-answered] $user: flagged $count in $box"
    else
      preview=$(head -n 20 <<<"$uids" | paste -sd, -)
      suffix=""
      if [ "$count" -gt 20 ]; then
        suffix=",…"
      fi
      echo "[backfill-answered] $user: would flag $count in $box (uids: ${preview}${suffix})"
    fi
    total_flagged=$((total_flagged + count))
  done < <(cut -f1 <<<"$matches" | sort -u)
done

if [ "$APPLY" -eq 1 ]; then
  echo "[backfill-answered] Done: flagged $total_flagged messages"
else
  echo "[backfill-answered] Dry run: $total_flagged messages would be flagged (re-run with --apply)"
fi
