data "aws_caller_identity" "current" {}

resource "aws_cognito_user_pool" "cabal_pool" {
  name                     = "cabal"
  auto_verified_attributes = [ "phone_number" ]
  sms_configuration {
    external_id    = "${data.aws_caller_identity.current.account_id}_DgEGa1t3qz"
    sns_caller_arn = aws_iam_role.cabal_sns_role.arn
  }
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_phone_number"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_client" "cabal_pool_client" {
  name         = "cabal_admin_client"
  user_pool_id = aws_cognito_user_pool.cabal_pool.id
  explicit_auth_flows = [
    "USER_PASSWORD_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_CUSTOM_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}