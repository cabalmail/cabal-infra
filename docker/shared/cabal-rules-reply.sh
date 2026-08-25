#!/bin/bash
# Composes and spools an auto-reply (vacation reply) for the message on
# stdin.
#
# Usage: cabal-rules-reply.sh <user> <base64-reply-body>
#
# Emitted by compile-user-rules.py for rules with the Reply auxiliary
# action (docs/1.x/user-mail-rules-plan.md, Phase 2c). The reply body
# arrives base64-encoded: user text never appears in procmail syntax, the
# recipe carries a fixed shape plus an opaque blob (and base64's alphabet
# contains no procmail SHELLMETAS, so the recipe still execs directly
# under SHELL=/usr/bin/false).
#
# The bounce-suppression guards (Auto-Submitted, Precedence, List-Id,
# MAILER-DAEMON, ...) live in the compiled recipe's CONDITIONS; this
# script owns the per-sender vacation cache (7-day suppression), the
# per-user daily rate cap, reply composition via formail -rt (To honors
# Reply-To, Subject gains a single Re:, References/In-Reply-To thread it,
# Auto-Submitted: auto-replied marks it per RFC 3834), and the From
# resolution: the reply comes FROM the address the original was delivered
# to, resolved by intersecting the user's virtusertable addresses with
# the original's To/Cc headers.
#
# Submission rides the same spool + root-drain split as forwards
# (cabal-forward-drain.sh): meta line {user, sender: <reply-From>,
# addrs: [<reply-To>]} followed by the composed RFC 5322 message.
# Suppression (cache hit, rate cap) exits 0 - it is the designed
# behavior, not a delivery failure; genuine failures exit non-zero into
# procmail's `w` accounting.
set -euo pipefail

SPOOL_DIR=/var/spool/cabal-forward
VIRTUSERTABLE=/etc/mail/virtusertable
ALIASES_DYNAMIC=/etc/aliases.dynamic
CACHE_FILE="$HOME/.cabal-rules-reply-cache"
COUNT_FILE="$HOME/.cabal-rules-reply-count"
CACHE_WINDOW_SECONDS=$((7 * 24 * 3600))
RATE_WINDOW_SECONDS=$((24 * 3600))
RATE_CAP=100
ADDR_RE='^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'

user="${1:?user required}"
body_b64="${2:?body required}"
if [ ! -d "$SPOOL_DIR" ]; then
  echo "[cabal-rules-reply] spool missing: $SPOOL_DIR" >&2
  exit 64
fi

work=$(mktemp)
trap 'rm -f "$work"' EXIT
cat > "$work"

now=$(date +%s)

# Rate cap: one timestamp per sent reply, pruned to the 24h window.
sent_today=0
if [ -f "$COUNT_FILE" ]; then
  sent_today=$(awk -v cutoff=$((now - RATE_WINDOW_SECONDS)) \
    '$1 > cutoff' "$COUNT_FILE" | wc -l)
fi
if [ "$sent_today" -ge "$RATE_CAP" ]; then
  echo "[cabal-rules-reply] rate cap reached ($RATE_CAP/24h); suppressing" >&2
  exit 0
fi

# The reply's To, as formail -rt will address it (honors Reply-To). Also
# the vacation-cache key. A target that does not parse as an address
# (formail's user@host fallback when the original is malformed) is a
# skip, not an error worth a bounce-adjacent retry.
# `|| true`: formail exits 67 on an original with no usable From; the
# empty/garbage target then fails the shape check below (the compiled
# recipe's `* ^From:.` guard makes this a defense-in-depth path only).
target=$(formail -rt < "$work" \
  | awk 'tolower($1) == "to:" { print $2; exit }' || true)
if ! [[ "$target" =~ $ADDR_RE ]]; then
  echo "[cabal-rules-reply] no usable reply target; skipping" >&2
  exit 0
fi
target=$(tr '[:upper:]' '[:lower:]' <<< "$target")

# Per-sender vacation suppression (7-day window).
if [ -f "$CACHE_FILE" ] \
    && awk -v cutoff=$((now - CACHE_WINDOW_SECONDS)) -v a="$target" \
         '$1 > cutoff && $2 == a { found = 1 } END { exit !found }' \
         "$CACHE_FILE"; then
  exit 0
fi

# Reply From: the user's own address the original was delivered to.
# virtusertable rows are "<address>\t<target>" where target is either a
# bare username or, for multi-user addresses, the combined alias name
# (user1_user2) that /etc/aliases.dynamic expands ("alias: u1, u2") -
# resolve through the alias file so shared addresses count as the
# user's. Intersect with the original's To/Cc, first match wins; a user
# whose addresses appear in neither (Bcc-style delivery) falls back to
# their first provisioned address. No addresses at all = nothing valid
# to reply from.
recipient=""
aliases_file="$ALIASES_DYNAMIC"
[ -f "$aliases_file" ] || aliases_file=/dev/null
declare -a my_addrs=()
while IFS= read -r addr; do
  my_addrs+=("$addr")
done < <(awk -v u="$user" '
  FNR == NR {
    if (match($0, /^[^:#[:space:]]+:/)) {
      alias = substr($0, 1, RSTART + RLENGTH - 2)
      rest = substr($0, RSTART + RLENGTH)
      gsub(/[[:space:]]/, "", rest)
      members[alias] = "," rest ","
    }
    next
  }
  $2 == u || index(members[$2], "," u ",") > 0 { print tolower($1) }
' "$aliases_file" "$VIRTUSERTABLE")
if [ ${#my_addrs[@]} -eq 0 ]; then
  echo "[cabal-rules-reply] no addresses for $user; skipping" >&2
  exit 0
fi
hdr_addrs=$(formail -czx To: -x Cc: < "$work" \
  | grep -oE '[^<>,[:space:]]+@[^<>,[:space:]]+' \
  | tr '[:upper:]' '[:lower:]' || true)
for addr in "${my_addrs[@]}"; do
  if grep -qxF "$addr" <<< "$hdr_addrs"; then
    recipient="$addr"
    break
  fi
done
recipient="${recipient:-${my_addrs[0]}}"

# Compose and spool. formail -rt's output ends with the header/body
# blank line, so the decoded body appends directly.
tmp=$(mktemp "$SPOOL_DIR/.tmp.XXXXXXXX")
trap 'rm -f "$work" "$tmp"' EXIT
{
  jq -cn --arg user "$user" --arg sender "$recipient" --arg to "$target" \
    '{user: $user, sender: $sender, addrs: [$to]}'
  formail -rt \
    -I "From: $recipient" \
    -A "Auto-Submitted: auto-replied" \
    -A "X-Loop: cabal-rules-${user}" < "$work"
  base64 -d <<< "$body_b64"
  echo
} > "$tmp"
mv "$tmp" "$SPOOL_DIR/fwd.${tmp##*/.tmp.}"
trap 'rm -f "$work"' EXIT

# Record only what was actually spooled: cache the sender for the 7-day
# window and count against the daily cap, pruning both files in place
# (write-then-rename; procmail may run deliveries concurrently, and
# losing one prune to a race is harmless).
{ [ -f "$CACHE_FILE" ] && awk -v cutoff=$((now - CACHE_WINDOW_SECONDS)) \
    '$1 > cutoff' "$CACHE_FILE"; echo "$now $target"; } > "${CACHE_FILE}.new"
mv "${CACHE_FILE}.new" "$CACHE_FILE"
{ [ -f "$COUNT_FILE" ] && awk -v cutoff=$((now - RATE_WINDOW_SECONDS)) \
    '$1 > cutoff' "$COUNT_FILE"; echo "$now"; } > "${COUNT_FILE}.new"
mv "${COUNT_FILE}.new" "$COUNT_FILE"
