/**
* Creates a Cognito User Pool for authentication against the management application and for authentication at the OS level (providing IMAP and SMTP authentication).
*/

locals {
  # SMS is on only when a 10DLC campaign registration id has been supplied.
  # A brand-new deploy has no such id (an approved campaign is a
  # weeks-of-carrier-review post-bootstrap step), so SMS starts off and the
  # pool must not require phone verification - otherwise Cognito falls
  # through to the shared SNS sandbox and signup fails with no user-facing
  # remediation. See issue #712 and docs/sms-10dlc.md.
  sms_enabled = var.ten_dlc_campaign_registration_id != ""
}

resource "aws_cognito_user_pool" "users" {
  name                       = "cabal"
  auto_verified_attributes   = local.sms_enabled ? ["phone_number"] : []
  sms_verification_message   = local.sms_enabled ? "Your Cabalmail verification code is {####}." : null
  sms_authentication_message = local.sms_enabled ? "Your Cabalmail verification code is {####}." : null

  dynamic "sms_configuration" {
    for_each = local.sms_enabled ? [1] : []
    content {
      sns_caller_arn = aws_iam_role.users.arn
      external_id    = "cabal-cognito-sms"
    }
  }

  # With SMS off there is no self-serve recovery channel (no email attribute
  # is collected either); admin_only leaves recovery to the operator via
  # AdminSetUserPassword. Once a 10DLC campaign lands, this flips back to
  # verified_phone_number automatically.
  account_recovery_setting {
    recovery_mechanism {
      name     = local.sms_enabled ? "verified_phone_number" : "admin_only"
      priority = 1
    }
  }

  schema {
    name                     = "osid"
    attribute_data_type      = "Number"
    developer_only_attribute = false
    mutable                  = true
    required                 = false
    number_attribute_constraints {
      min_value = 2000
    }
  }
  lambda_config {
    post_confirmation = aws_lambda_function.assign_osid.arn
    pre_sign_up       = aws_lambda_function.check_invite.arn
  }

  # Threat protection requires the Plus feature plan; on the default
  # ESSENTIALS tier, UpdateUserPool rejects the add-on below with
  # FeatureUnavailableInTierException. Plus bills $0.02/MAU from the first
  # user (Essentials has a 10k-MAU free allowance, Plus has none), so this
  # line is where the pool starts costing money - a deliberate decision.
  user_pool_tier = "PLUS"

  # Cognito threat protection in AUDIT mode: score sign-in risk (impossible
  # travel, compromised credentials) and surface it in CloudWatch without
  # blocking the user. Promotion to ENFORCED is a deliberate later step
  # (plan Phase 2.5) after a soak period to calibrate false positives.
  user_pool_add_ons {
    advanced_security_mode = "AUDIT"
  }
}

# AWS End User Messaging 10DLC number used by the SNS SMS path. Created
# only once the account's 10DLC campaign registration is approved and
# its id is supplied; requesting a number against an unapproved or
# absent campaign fails.
#
# Create waits for the number to reach ACTIVE, which for 10DLC includes
# the carrier-side campaign/number association; usually minutes, but if
# it exceeds the timeout the apply fails with the number left tainted -
# re-apply rather than releasing it by hand.
#
# The HELP/STOP/START keyword auto-responses on this number must match
# the messages registered with the campaign; the provider has no keyword
# resource, so a post-apply step (put-sms-keywords.sh in infra.yml)
# owns them.
resource "aws_pinpointsmsvoicev2_phone_number" "ten_dlc" {
  count                       = var.ten_dlc_campaign_registration_id != "" ? 1 : 0
  iso_country_code            = "US"
  message_type                = "TRANSACTIONAL"
  number_capabilities         = ["SMS"]
  number_type                 = "TEN_DLC"
  registration_id             = var.ten_dlc_campaign_registration_id
  deletion_protection_enabled = true

  timeouts {
    create = "30m"
  }
}

resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.users.id
  description  = "Administrators with access to user management"
}

resource "aws_cognito_user_pool_client" "users" {
  name                = "cabal_admin_client"
  user_pool_id        = aws_cognito_user_pool.users.id
  explicit_auth_flows = ["USER_PASSWORD_AUTH"]

  access_token_validity  = 12
  id_token_validity      = 12
  refresh_token_validity = 7
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Bound a stolen/leaked refresh token to 7 days of exposure instead of the
  # 30-day default. enable_token_revocation defaults to true, but state it so
  # admin-user-global-sign-out reliably invalidates issued tokens.
  enable_token_revocation = true
}

# Hosted-UI domain prefix used by the ALB authenticate-oidc action in the
# monitoring module. Creating it here (singleton per pool) lets it exist
# even when `var.monitoring = false` - inexpensive and avoids the need
# to destroy-and-recreate it when monitoring is toggled.
resource "aws_cognito_user_pool_domain" "users" {
  domain       = "cabal-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.users.id
}
