# Service account for the post-deploy mail probe (.github/scripts/mail-probe.py,
# run by the mail-probe job in app.yml after a mail-tier or API deploy).
#
# The probe signs in as this user, sends it one message through /send and one
# straight at the public MX, and confirms both reach its INBOX. It owns exactly
# one address, ci-probe@mail-admin.<first mail domain>, on the same system
# subdomain as the dmarc user's addresses, so it inherits mail-admin's MX, SPF,
# DKIM and DMARC records (dmarc_user.tf) without any of its own.
#
# Same shape as the master and dmarc users: a Terraform-minted password (the
# accepted in-state exception for secrets Terraform itself generates), a
# Cognito user with a pinned osid so sync-users.sh gives it the same uid on
# every container (9999 master, 9998 dmarc, 9997 ci-probe), and an address
# row. The password is published to SSM for the CI deploy role, whose
# reference policy (docs/aws.md) already covers ssm:GetParameter.
#
# The pool's pre-sign-up trigger (check_invite) fires for AdminCreateUser
# too; it exempts that trigger source, since the caller is already
# IAM-authorized, which is what lets this apply succeed while the invitation
# code is set. Passing the code as validation_data does not work: the
# provider normalizes those keys like user attributes, so the trigger sees
# custom:invitationCode.
#
# The containers learn about the user on their own schedule: sync-users.sh
# runs only at container start, so the imap tier has to roll once after the
# apply before the probe's api leg can pass, and smtp-in adds the address to
# its access map on its next reconfigure event or roll. docs/mail-probe.md
# lists the failure signatures of a probe that ran before that.

resource "random_password" "ci_probe_password" {
  length           = 24
  special          = true
  override_special = "()-_=+[]<>:"
  # One character per class, pinned: the pool's default password policy
  # requires all four and random_password only guarantees length otherwise
  # (password.tf records the apply that taught us this).
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1
}

resource "aws_cognito_user" "ci_probe" {
  user_pool_id = var.user_pool_id
  username     = "ci-probe"
  enabled      = true
  password     = random_password.ci_probe_password.result
  attributes = {
    osid = 9997
  }
}

resource "aws_ssm_parameter" "ci_probe_password" {
  name        = "/cabal/ci-probe/password"
  description = "Password for the ci-probe Cognito user, read by app.yml's mail-probe job"
  type        = "SecureString"
  value       = random_password.ci_probe_password.result
}

# Address record so mail to ci-probe@mail-admin.<domain> is delivered to the
# ci-probe user. The probe reads it back through /list, so the address never
# has to be configured on the CI side.
resource "aws_dynamodb_table_item" "ci_probe_address" {
  table_name = "cabal-addresses"
  hash_key   = "address"
  item = jsonencode({
    address   = { S = "ci-probe@mail-admin.${var.domains[0].domain}" }
    tld       = { S = var.domains[0].domain }
    user      = { S = "ci-probe" }
    username  = { S = "ci-probe" }
    subdomain = { S = "mail-admin" }
    comment   = { S = "System address for the post-deploy mail probe" }
  })

  depends_on = [aws_cognito_user.ci_probe]
}
