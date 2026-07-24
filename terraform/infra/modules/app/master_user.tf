# Service account for the mail path: /send submits SMTP as `master`
# (smtp-out Dovecot authenticates it against Cognito via cognito.bash),
# and the IMAP master-login password is derived from the same secret.
# Deliberately NOT in the Cognito admin group: nothing consumes that
# membership (submission auth is a bare password check, IMAP master login
# is a local htpasswd file, and master never calls the admin API), and a
# headless account can never satisfy the require_admin_mfa gate - its
# membership was the one thing standing between the identity plan and
# flipping admin-MFA enforcement.
resource "aws_cognito_user" "master" {
  user_pool_id = var.user_pool_id
  username     = "master"
  enabled      = true
  password     = random_password.password.result
  attributes = {
    osid = 9999
  }
}
