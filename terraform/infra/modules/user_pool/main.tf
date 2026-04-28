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
  }
}

resource "aws_pinpointsmsvoicev2_phone_number" "sms" {
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
