#!/bin/bash
# Maintain a /etc/hosts pin for IMAP_INTERNAL_HOST so a transient Cloud
# Map outage degrades from a permanent 5xx ("Host unknown") to a
# queueable 4xx (TCP connection refused / timeout). Sendmail retries
# 4xx for ~4 days before giving up, which is plenty of head-room for
# any realistic orchestration glitch.
#
# Intentionally smtp-in only. smtp-out keeps stock DNS resolution so
# outbound mail to a non-existent recipient domain still bounces fast
# rather than sitting in the queue for days.
#
# For the pin to be honored, sendmail must consult /etc/hosts before
# DNS. The smtp-in image ships /etc/mail/service.switch with
# `hosts files dns` and points confSERVICE_SWITCH_FILE at it; without
# that, sendmail can go straight to the resolver and the pin is a no-op.
#
# Resolves via `dig` directly to the VPC resolver from /etc/resolv.conf.
# We do NOT use getent / gethostbyname for the lookup, since those read
# /etc/hosts first and would feedback-loop on our own pin.
#
# The pin is never absent while this runs: TARGET must always resolve to
# *something*, because a missing entry lets sendmail fall through to DNS,
# NXDOMAIN, and a permanent 5xx bounce. Order of preference on any
# refresh: freshly resolved IMAP IP > existing pin (stale real IP or
# sentinel) > sentinel. A stale or sentinel pin TCP-fails exactly like
# the real host being down (4xx, queued) and is overwritten by the next
# successful resolve via the diff-and-overwrite below, so it converges
# to the real IP within one interval of IMAP becoming resolvable again.
#
# Modes:
#   init    one-shot resolve + write, then exit 0. Called from
#           entrypoint.sh before supervisord starts sendmail, so the
#           first delivery attempt already sees a pin. On resolve
#           failure it writes the sentinel (cold start during an IMAP
#           outage) rather than leaving TARGET unresolvable.
#   daemon  refresh every $HOSTS_PIN_INTERVAL (default 30s). Started by
#           supervisord. On resolve failure it keeps the existing pin
#           (or writes the sentinel if none exists yet) and retries on
#           the next tick.
set -eu

TARGET="${IMAP_INTERNAL_HOST:-imap.cabal.internal}"
MARKER="# cabal-hosts-pin"
HOSTS=/etc/hosts
INTERVAL="${HOSTS_PIN_INTERVAL:-30}"
# RFC 5737 TEST-NET-1: guaranteed never routed, so a connect attempt
# TCP-times-out and sendmail defers (4xx) instead of bouncing. Override
# with HOSTS_PIN_SENTINEL if a faster-failing in-VPC black hole exists.
SENTINEL="${HOSTS_PIN_SENTINEL:-192.0.2.1}"

NS="$(awk '/^nameserver /{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
if [ -z "${NS:-}" ]; then
  echo "[hosts-pin] no nameserver in /etc/resolv.conf; refusing to start" >&2
  exit 1
fi

resolve() {
  dig +short +time=2 +tries=1 "@$NS" A "$TARGET" 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | head -n1
}

current_pin() {
  awk -v t="$TARGET" -v m="$MARKER" '$2 == t && index($0, m) {print $1; exit}' "$HOSTS"
}

write_pin() {
  ip="$1"
  # Write IN PLACE. /etc/hosts is a bind mount inside the container, so
  # it cannot be replaced by rename(2): the staged temp lives on the
  # overlay fs while /etc/hosts is mounted from the host fs, making the
  # rename cross-device, and mv's copy fallback misses the live mounted
  # file - the pin silently never lands and sendmail keeps falling
  # through to DNS (a 5xx bounce). So we stage the new content beside it,
  # then truncate-and-rewrite the mounted file with a single cat. The
  # truncate-to-write window is a few microseconds for a file this small;
  # a sendmail read racing exactly into it is far less harmful than never
  # updating the pin at all.
  tmp="${HOSTS}.tmp"
  grep -v "$MARKER" "$HOSTS" > "$tmp" 2>/dev/null || true
  echo "$ip $TARGET $MARKER" >> "$tmp"
  cat "$tmp" > "$HOSTS"
  rm -f "$tmp"
  echo "[hosts-pin] $TARGET -> $ip"
}

# Log the namespace SOA so the worst-case NXDOMAIN-cache window - which
# bounds how long after IMAP returns the pin can stay stale - is
# observable in the container logs. RFC 2308: effective negative-cache
# TTL = min(SOA record TTL, SOA MINIMUM field).
log_soa_negttl() {
  zone="${TARGET#*.}"
  line="$(dig +time=2 +tries=1 "@$NS" SOA "$zone" +noall +answer 2>/dev/null | head -n1 || true)"
  if [ -z "$line" ]; then
    echo "[hosts-pin] SOA lookup for $zone failed; negative-cache TTL unknown"
    return 0
  fi
  rec_ttl="$(echo "$line" | awk '{print $2}')"
  soa_min="$(echo "$line" | awk '{print $NF}')"
  echo "[hosts-pin] $zone SOA record-ttl=${rec_ttl}s minimum=${soa_min}s (worst-case NXDOMAIN cache approx the min of those)"
}

# Resolve TARGET and update the pin.
#   return 0  pin now holds the freshly resolved IMAP IP
#   return 1  resolve failed; existing pin kept, or sentinel written if
#             no pin existed yet. TARGET stays resolvable either way.
refresh_once() {
  ip="$(resolve)"
  if [ -n "$ip" ]; then
    pin="$(current_pin || true)"
    if [ "$ip" != "$pin" ]; then
      write_pin "$ip"
    fi
    return 0
  fi
  if [ -z "$(current_pin || true)" ]; then
    write_pin "$SENTINEL"
    echo "[hosts-pin] resolve failed with no prior pin; wrote sentinel (defers as 4xx until IMAP returns)"
  fi
  return 1
}

case "${1:-daemon}" in
  init)
    if ! refresh_once; then
      echo "[hosts-pin] init: real IMAP IP unavailable; left sentinel/stale pin, daemon will converge" >&2
    fi
    ;;
  daemon)
    echo "[hosts-pin] daemon: target=$TARGET resolver=$NS interval=${INTERVAL}s sentinel=$SENTINEL"
    log_soa_negttl
    while :; do
      sleep "$INTERVAL"
      if ! refresh_once; then
        echo "[hosts-pin] resolve empty; keeping pin ($(current_pin || echo none))"
      fi
    done
    ;;
  *)
    echo "usage: $0 [init|daemon]" >&2
    exit 1
    ;;
esac
