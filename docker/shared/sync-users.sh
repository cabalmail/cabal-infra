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

  # Ensure home directory structure (idempotent)
  mkdir -p "/home/${username}/Maildir" "/home/${username}/.procmail"
  cp -n /etc/procmailrc "/home/${username}/.procmailrc" 2>/dev/null || true
  chown -R "${username}:${username}" "/home/${username}"
  chmod 700 "/home/${username}" "/home/${username}/Maildir"
  chmod 755 "/home/${username}/.procmail"
done

echo "[sync-users] Done."
