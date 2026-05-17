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
  # custom_sms_sender (Twilio) is feature-flagged per env via
  # var.use_twilio_sms. When the flag is true Cognito hands SMS
  # delivery to the sms-sender Lambda, encrypts OTPs with the
  # provided KMS key, and bypasses the SNS hot path. The
  # sms_configuration block above stays in place because Cognito
  # still validates it whenever a phone attribute is auto-verified.
  # See docs/twilio.md.
  lambda_config {
    post_confirmation = aws_lambda_function.assign_osid.arn

    dynamic "custom_sms_sender" {
      for_each = var.use_twilio_sms ? [1] : []
      content {
        lambda_arn     = var.sms_sender_arn
        lambda_version = "V1_0"
      }
    }

    kms_key_id = var.use_twilio_sms ? var.sms_kms_key_arn : null
  }
}

# AWS End User Messaging toll-free number used by the legacy SNS SMS
# path. Gated on var.use_eum_sms so environments that have committed
# to the Twilio path don't carry the EUM number (and its monthly
# rental + pending TFV registration) as dead weight. See docs/twilio.md.
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

# Migrate state from the pre-count resource address so an env that
# already had a (pending or active) EUM phone number does not see a
# destroy on the un-indexed address. Combined with
# deletion_protection_enabled = true this means a TFV-approved
# number cannot be lost by a flag flip alone.
moved {
  from = aws_pinpointsmsvoicev2_phone_number.sms
  to   = aws_pinpointsmsvoicev2_phone_number.sms[0]
}

resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.users.id
  description  = "Administrators with access to user management"
}

resource "aws_cognito_user_pool_client" "users" {
  name                  = "cabal_admin_client"
  user_pool_id          = aws_cognito_user_pool.users.id
  explicit_auth_flows   = ["USER_PASSWORD_AUTH"]
  access_token_validity = 12
  id_token_validity     = 12
}

# Hosted-UI domain prefix used by the ALB authenticate-oidc action in the
# monitoring module. Creating it here (singleton per pool) lets it exist
# even when `var.monitoring = false` - inexpensive and avoids the need
# to destroy-and-recreate it when monitoring is toggled.
resource "aws_cognito_user_pool_domain" "users" {
  domain       = "cabal-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.users.id
}
