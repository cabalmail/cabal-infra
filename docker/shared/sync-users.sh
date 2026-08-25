#!/bin/bash
# Fetches users from Cognito and creates OS accounts.
#
# Replaces: chef/cabal/recipes/_common_users.rb
#           chef/cabal/libraries/users.rb
#
# Required env vars: COGNITO_POOL_ID, AWS_REGION
set -euo pipefail

echo "[sync-users] Fetching users from Cognito pool $COGNITO_POOL_ID..."

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
' | sort -n | while read -r osid username; do

  # Create group and user if they don't exist
  if ! getent group "$username" >/dev/null 2>&1; then
    groupadd -g "$osid" "$username"
    echo "[sync-users] Created group $username (gid=$osid)"
  fi
  if ! getent passwd "$username" >/dev/null 2>&1; then
    useradd -u "$osid" -g "$osid" -m "$username"
    echo "[sync-users] Created user $username (uid=$osid)"
  fi

  # Ensure home directory structure (idempotent).
  # UIDs are constant (Cognito custom:osid), so ownership is correct from
  # useradd — no recursive chown needed.  A recursive chown on EFS is
  # extremely slow with large Maildirs and blocks startup long enough for
  # ECS to kill the task.  install -d sets owner/mode atomically and only
  # touches the named directories themselves.
  install -d -o "$username" -g "$username" -m 700 \
    "/home/${username}/Maildir"
  install -d -o "$username" -g "$username" -m 755 \
    "/home/${username}/.procmail"
  # ~/.procmailrc is system-owned (users have no shell access), so install
  # the CURRENT template on every sync rather than copy-once: recipe
  # ordering changes (e.g. the user-rules include landing before the push
  # recipe, docs/1.x/user-mail-rules-plan.md) must reach existing users,
  # not just new ones. The in-file guards (CABALRULESDONE, PUSH_ENQUEUED)
  # make double-processing of /etc/procmailrc + this copy harmless.
  # Guarded: only the imap image ships /etc/procmailrc - smtp-out runs
  # this script too (submission auth needs the OS users) but does no
  # local delivery, and an unguarded install of a missing file aborts
  # the whole sync under set -e.
  if [ -f /etc/procmailrc ]; then
    install -o "$username" -g "$username" -m 644 \
      /etc/procmailrc "/home/${username}/.procmailrc"
  fi
done

echo "[sync-users] Done."
