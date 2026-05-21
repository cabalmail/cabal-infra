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
# Resolves via `dig` directly to the VPC resolver from /etc/resolv.conf.
# We do NOT use getent / gethostbyname for the lookup, since those read
# /etc/hosts first and would feedback-loop on our own pin.
#
# Modes:
#   init    one-shot resolve + write, then exit. Called from
#           entrypoint.sh before supervisord starts sendmail, so the
#           first delivery attempt already sees the pin.
#   daemon  refresh every $HOSTS_PIN_INTERVAL (default 30s). Started by
#           supervisord. On resolve failure (Cloud Map empty), keeps
#           the existing pin in place rather than removing it - a
#           stale-but-present pin yields a 4xx on TCP connect, whereas
#           no pin at all falls back to DNS and yields a 5xx NXDOMAIN.
set -eu

TARGET="${IMAP_INTERNAL_HOST:-imap.cabal.internal}"
MARKER="# cabal-hosts-pin"
HOSTS=/etc/hosts
INTERVAL="${HOSTS_PIN_INTERVAL:-30}"

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
  tmp="$(mktemp)"
  grep -v "$MARKER" "$HOSTS" > "$tmp" 2>/dev/null || true
  echo "$ip $TARGET $MARKER" >> "$tmp"
  cat "$tmp" > "$HOSTS"
  rm -f "$tmp"
  echo "[hosts-pin] $TARGET -> $ip"
}

refresh_once() {
  ip="$(resolve)"
  if [ -z "$ip" ]; then
    return 1
  fi
  pin="$(current_pin || true)"
  if [ "$ip" != "$pin" ]; then
    write_pin "$ip"
  fi
}

case "${1:-daemon}" in
  init)
    if ! refresh_once; then
      echo "[hosts-pin] init: resolve via $NS failed; no pin written" >&2
      exit 1
    fi
    ;;
  daemon)
    echo "[hosts-pin] daemon: target=$TARGET resolver=$NS interval=${INTERVAL}s"
    while :; do
      sleep "$INTERVAL"
      if ! refresh_once; then
        echo "[hosts-pin] resolve empty; keeping existing pin ($(current_pin || echo none))"
      fi
    done
    ;;
  *)
    echo "usage: $0 [init|daemon]" >&2
    exit 1
    ;;
esac
