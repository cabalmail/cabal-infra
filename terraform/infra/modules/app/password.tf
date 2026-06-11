# Password for IMAP admin
resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "()-_=+[]<>:"
  # The Cognito user pool uses the default password policy, which requires
  # at least one character from every class. random_password only
  # guarantees length unless the minimums are pinned, and a draw missing a
  # class wedges every subsequent apply at aws_cognito_user.master (the
  # value is stable in state, so it never re-rolls on its own). Pinning
  # the minimums forces a one-time regeneration on existing environments:
  # SSM and the Cognito master user rotate together in the same apply.
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1
}

# Save admin password in parameter store.
resource "aws_ssm_parameter" "password" {
  name        = "/cabal/master_password"
  description = "Master IMAP password"
  type        = "SecureString"
  value       = random_password.password.result
}
