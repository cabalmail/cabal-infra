- **Cognito user-existence check named once.** `assign_address`,
  `new_address_admin` and `set_user_domain_access` each carried a private
  `cognito_user_exists()` and its own `cognito-idp` client; the check now
  lives in `admin_limits.py` beside the other admin-handler guards, taking
  the caller's user-pool id as an argument so every import-time environment
  read stays where it was.
