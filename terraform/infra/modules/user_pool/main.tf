/**
* Creates a Cognito User Pool for authentication against the management application and for authentication at the OS level (providing IMAP and SMTP authentication).
*/

resource "aws_cognito_user_pool" "users" {
  name                     = "cabal"
  auto_verified_attributes = ["phone_number"]
  sms_verification_message = "Your Cabalmail verification code is {####}"

  sms_configuration {
    sns_caller_arn = aws_iam_role.users.arn
    external_id    = "cabal-cognito-sms"
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_phone_number"
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

# AWS End User Messaging toll-free number used by the SNS SMS path.
# Gated on var.use_eum_sms.
#
# Note: deletion_protection_enabled = true means flipping this flag
# from true to false will fail apply until protection is disabled in
# a prior apply. That's intentional - losing a TFV-approved number is
# expensive.
resource "aws_pinpointsmsvoicev2_phone_number" "sms" {
  count                       = var.use_eum_sms ? 1 : 0
  iso_country_code            = "US"
  message_type                = "TRANSACTIONAL"
  number_capabilities         = ["SMS"]
  number_type                 = "TOLL_FREE"
  deletion_protection_enabled = true

  timeouts {
    create = "1m"
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
