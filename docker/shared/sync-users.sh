#!/bin/bash
# Fetches users from Cognito and creates OS accounts.
#
# Replaces: chef/cabal/recipes/_common_users.rb
#           chef/cabal/libraries/users.rb
#
# Required env vars: COGNITO_POOL_ID, AWS_REGION
set -euo pipefail

# A Cognito username becomes an OS login name here. SAFE_NAME is the floor
# for what one may look like: a name outside it is skipped, never created.
# It is wider than the sign-up rule check_invite enforces
# (lambda/counter/check_invite): it also passes uppercase letters,
# underscores, inner dots and names shorter than three characters, all of
# which the image's useradd accepts. An all-digit name is refused too: a
# login name is never all digits.
SAFE_NAME='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$'

# Logs why one user is skipped: skip <username> <osid> <reason>.
skip() {
  echo "[sync-users] SKIP $1 (osid=$2): $3" >&2
}

# Provision one user. Returns non-zero, having said why, when this user is
# skipped. Called in an `||` context, where bash ignores `set -e` for the
# whole function body - so every step that can fail carries its own
# `|| return 1`; an unguarded failure here would fall through silently.
sync_user() {
  local osid="$1" username="$2"
  local group_entry="" account_entry="" name uid gid

  if [[ ! "$osid" =~ ^[0-9]+$ ]]; then
    echo "[sync-users] SKIP $username: custom:osid '$osid' is not a number" >&2
    return 1
  fi
  if [[ ! "$username" =~ $SAFE_NAME ]] || [[ "$username" =~ ^[0-9]+$ ]]; then
    echo "[sync-users] SKIP osid=$osid: username $(printf %q "$username") is not a safe OS login name" >&2
    return 1
  fi

  # An existing group or account with this name is reused only when it
  # carries this user's osid, which is what an earlier pass in this
  # container created; otherwise the user is skipped. Both are checked
  # before either is created, so a skipped user leaves nothing behind.
  if group_entry=$(getent group -- "$username"); then
    IFS=: read -r name _ gid _ <<<"$group_entry"
    if [ "$name" != "$username" ] || [ "$gid" != "$osid" ]; then
      skip "$username" "$osid" "group exists with gid=$gid"
      return 1
    fi
  else
    group_entry=""
  fi
  if account_entry=$(getent passwd -- "$username"); then
    IFS=: read -r name _ uid gid _ <<<"$account_entry"
    if [ "$name" != "$username" ] || [ "$uid" != "$osid" ] || [ "$gid" != "$osid" ]; then
      skip "$username" "$osid" "account exists with uid=$uid gid=$gid"
      return 1
    fi
  else
    account_entry=""
  fi

  if [ -z "$group_entry" ]; then
    groupadd -g "$osid" "$username" \
      || { skip "$username" "$osid" "groupadd failed"; return 1; }
    echo "[sync-users] Created group $username (gid=$osid)"
  fi
  if [ -z "$account_entry" ]; then
    useradd -u "$osid" -g "$osid" -m "$username" \
      || { skip "$username" "$osid" "useradd failed"; return 1; }
    echo "[sync-users] Created user $username (uid=$osid)"
  fi

  # Ensure home directory structure (idempotent).
  # UIDs are constant (Cognito custom:osid), so ownership is correct from
  # useradd — no recursive chown needed.  A recursive chown on EFS is
  # extremely slow with large Maildirs and blocks startup long enough for
  # ECS to kill the task.  install -d sets owner/mode atomically and only
  # touches the named directories themselves.
  install -d -o "$username" -g "$username" -m 700 \
    "/home/${username}/Maildir" \
    || { skip "$username" "$osid" "creating ~/Maildir failed"; return 1; }
  install -d -o "$username" -g "$username" -m 755 \
    "/home/${username}/.procmail" \
    || { skip "$username" "$osid" "creating ~/.procmail failed"; return 1; }
  # ~/.procmailrc is system-owned (users have no shell access), so install
  # the CURRENT template on every sync rather than copy-once: recipe
  # ordering changes (e.g. the user-rules include landing before the push
  # recipe, docs/1.x/user-mail-rules-plan.md) must reach existing users,
  # not just new ones. The in-file guards (CABALRULESDONE, PUSH_ENQUEUED)
  # make double-processing of /etc/procmailrc + this copy harmless.
  # Guarded: only the imap image ships /etc/procmailrc - smtp-out runs
  # this script too (submission auth needs the OS users) but does no
  # local delivery, so it has no file to install.
  if [ -f /etc/procmailrc ]; then
    # Only when the content differs: this script now runs on every
    # reconfigure pass, not just at container start (#1721), and `install`
    # writes the destination in place - a procmail invocation reading
    # ~/.procmailrc mid-write would see a partial file. A no-op pass must
    # not touch the file at all.
    if ! cmp -s /etc/procmailrc "/home/${username}/.procmailrc"; then
      install -o "$username" -g "$username" -m 644 \
        /etc/procmailrc "/home/${username}/.procmailrc" \
        || { skip "$username" "$osid" "installing ~/.procmailrc failed"; return 1; }
    fi
    # Heal ~/.procmail/log ownership: before DROPPRIVS landed in
    # procmailrc, the privileged /etc/procmailrc pass could leave the
    # log root-owned on EFS, permanently blocking the recipient's own
    # appends. One chown per sync is cheap and idempotent.
    if [ -f "/home/${username}/.procmail/log" ]; then
      chown "$username:$username" "/home/${username}/.procmail/log" \
        || { skip "$username" "$osid" "chown of ~/.procmail/log failed"; return 1; }
    fi
  fi
}

echo "[sync-users] Fetching users from Cognito pool $COGNITO_POOL_ID..."

# Each user is provisioned on its own: one the sync cannot create is
# logged and counted, and the loop goes on to the next. A skip never fails
# the script; keep it that way, since entrypoint.sh runs this under
# `set -e`. A failed list-users (or jq) still fails the pipeline under
# pipefail.
aws cognito-idp list-users \
  --user-pool-id "$COGNITO_POOL_ID" \
  --region "$AWS_REGION" \
  --output json \
| jq -r '
  .Users[]
  | select(.UserStatus == "CONFIRMED")
  | select(.Attributes[]? | select(.Name == "custom:osid"))
  | {
      username: .Username,
      osid: (.Attributes[] | select(.Name == "custom:osid") | .Value)
    }
  | "\(.osid) \(.username)"
' | sort -n | {
  skipped=0
  while read -r osid username; do
    sync_user "$osid" "$username" || skipped=$((skipped + 1))
  done
  if [ "$skipped" -gt 0 ]; then
    echo "[sync-users] ERROR: skipped $skipped user(s); see SKIP lines above" >&2
  fi
}

echo "[sync-users] Done."
