# Password for IMAP admin
resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "()-_=+[]<>:"
}

# Save admin password in parameter store.
resource "aws_ssm_parameter" "password" {
  name        = "/cabal/master_password"
  description = "Master IMAP password"
  type        = "SecureString"
  value       = random_password.password.result
}
