#!/bin/bash
# How reconfigure.sh restarts sendmail without supervisord counting the
# restart as a failed start, and how it tells that no restart is needed.
#
# reconfigure.sh restarts sendmail by killing it and letting supervisord
# start it again. supervisord judges a program by how long it lived: an
# exit within `startsecs` (5) of the start is a failed start, the retries
# wait 1, 2 and 3 seconds, and the fourth failed start in a row puts the
# program in FATAL, which supervisord never leaves by itself. A pass of
# reconfigure.sh takes about five seconds, so messages arriving one after
# another gave kills about five seconds apart: stage logged three failed
# starts in a row three times, one short of FATAL, and prod's closest
# calls cleared the five seconds by 25 ms (issue #2450). Two rules close
# that, both here:
#
#   1. Never kill a sendmail that supervisord started less than
#      SENDMAIL_MIN_AGE seconds ago; wait until it is that old. The age is
#      read from the process supervisord started, whose start time is the
#      clock supervisord itself uses (sendmail-wrapper.sh `exec`s
#      sendmail, so the wrapper and the daemon are one process). A kill
#      from here can therefore never be a failed start, however fast the
#      messages come.
#   2. A pass that a queue message started restarts sendmail only when a
#      file sendmail reads has changed since it started. Most messages
#      change none: a rule save or a flag change touches procmail's
#      files, and a confirmed address only the pending-address recipe.
#      The periodic fallback pass restarts sendmail whatever the files
#      say, as it always has, so a mistake in rule 2 lasts 15 minutes at
#      most.
#
# Sourced, not executed. Used by reconfigure.sh (which runs under
# `set -euo pipefail`) and by sendmail-wrapper.sh (which does not), so
# nothing here depends on either.

# Seconds supervisord's sendmail must have been up before it is killed.
# Three times the `startsecs=5` in each tier's supervisord.conf.
SENDMAIL_MIN_AGE="${SENDMAIL_MIN_AGE:-15}"

# Where sendmail-wrapper.sh records what sendmail started with.
SENDMAIL_LOADED_DIGEST="${SENDMAIL_LOADED_DIGEST:-/run/sendmail-loaded.digest}"

# What sendmail reads. Everything generate-config.sh and
# assemble-aliases.sh write for it is in here.
SENDMAIL_INPUT_DIR="${SENDMAIL_INPUT_DIR:-/etc/mail}"
SENDMAIL_ALIASES="${SENDMAIL_ALIASES:-/etc/aliases}"

# supervisord's pid. reconfigure.sh is a supervisord program, so its
# parent is supervisord. (Run by hand from another shell, nothing is
# found under that shell and rule 1 does not wait.)
SENDMAIL_SUPERVISOR_PID="${SENDMAIL_SUPERVISOR_PID:-$PPID}"

# Prints one digest of the names and contents of the files sendmail
# reads. The map sources stand for their .db files, which makemap
# rebuilds from them on every pass; .tmp is generate-config.sh's
# write-then-rename staging name. Every other regular file in the
# directory counts, so a file a later change starts generating is covered
# without a list to keep in step. Returns non-zero, printing nothing, if
# a file cannot be read.
sendmail_inputs_digest() {
  local f one sums=""
  for f in "$SENDMAIL_INPUT_DIR"/* "$SENDMAIL_ALIASES"; do
    case "$f" in *.db | *.tmp) continue ;; esac
    [ -f "$f" ] || continue
    one=$(sha256sum < "$f") || return 1
    sums+="$f $one"$'\n'
  done
  one=$(printf '%s' "$sums" | sha256sum) || return 1
  printf '%s\n' "${one%% *}"
}

# Called by sendmail-wrapper.sh just before it starts sendmail: records
# what that sendmail is about to read. Taken BEFORE the start on purpose.
# If a file changes between this and sendmail reading it, the record is
# older than what sendmail holds and the next pass restarts once more
# than it needed to; taken after, a change in that gap would be missed.
# With no record, sendmail_inputs_changed says "changed".
sendmail_record_loaded_inputs() {
  local digest
  if digest=$(sendmail_inputs_digest) && [ -n "$digest" ] \
    && printf '%s\n' "$digest" > "$SENDMAIL_LOADED_DIGEST.tmp" \
    && mv -f "$SENDMAIL_LOADED_DIGEST.tmp" "$SENDMAIL_LOADED_DIGEST"; then
    return 0
  fi
  rm -f "$SENDMAIL_LOADED_DIGEST" "$SENDMAIL_LOADED_DIGEST.tmp"
  return 1
}

# True (0) when the files on disk are not the ones the running sendmail
# started with, and also whenever that cannot be told: no record, an
# unreadable file. Doubt restarts, which is what every pass did before.
sendmail_inputs_changed() {
  local now loaded
  now=$(sendmail_inputs_digest) || return 0
  [ -n "$now" ] || return 0
  [ -r "$SENDMAIL_LOADED_DIGEST" ] || return 0
  loaded=$(cat "$SENDMAIL_LOADED_DIGEST" 2> /dev/null) || return 0
  [ "$now" != "$loaded" ]
}

# Prints how many whole seconds ago supervisord started its sendmail
# program. Returns 1, printing nothing, when supervisord has no such
# child (it is waiting out a retry, or has given up) or its age cannot be
# read. The child is named for the wrapper until the wrapper's `exec`
# ("sendmail-wrappe": the kernel keeps 15 characters) and "sendmail"
# after; it is one process with one start time throughout, so both names
# are asked for. Looking under supervisord's pid keeps sendmail's own
# children, and a sendmail run by a delivery helper, out of the answer.
sendmail_supervised_age() {
  local pid age
  pid=$(pgrep -x -P "$SENDMAIL_SUPERVISOR_PID" 'sendmail|sendmail-wrappe' 2> /dev/null | head -n 1) || true
  [ -n "$pid" ] || return 1
  age=$(ps -o etimes= -p "$pid" 2> /dev/null | tr -d '[:space:]') || true
  [[ "$age" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$age"
}

# Returns once supervisord's sendmail has been up SENDMAIL_MIN_AGE
# seconds, or supervisord has none. Returns 1 if, after four times that
# long, there is still one and it is still too young: it is not staying
# up, for a reason that is not this script's.
#
# Why "has none" needs no wait: the caller's kill follows within
# milliseconds, and a process that did not exist a moment ago cannot be
# killed by name yet, because the wrapper sleeps a second before it
# becomes sendmail.
sendmail_wait_until_settled() {
  local age waited=0 limit=$((SENDMAIL_MIN_AGE * 4))
  while age=$(sendmail_supervised_age) && [ "$age" -lt "$SENDMAIL_MIN_AGE" ]; do
    if [ "$waited" -eq 0 ]; then
      echo "[reconfigure] sendmail was started ${age}s ago; waiting until it has been up ${SENDMAIL_MIN_AGE}s before restarting it"
    fi
    if [ "$waited" -ge "$limit" ]; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

# Kills sendmail so that supervisord starts it again with the files now
# on disk; rule 1 above. supervisorctl is not configured (no
# unix_http_server / supervisorctl section in supervisord.conf), and the
# wrapper removes any stale daemon and PID file before it starts
# sendmail, so a plain pkill is safe.
sendmail_restart() {
  if ! sendmail_wait_until_settled; then
    echo "[reconfigure] sendmail is not staying up ${SENDMAIL_MIN_AGE}s; not killing it. It reads the new files at its next start."
    return 0
  fi
  echo "[reconfigure] Killing sendmail; supervisord will restart it..."
  pkill -x sendmail 2> /dev/null || true
}
