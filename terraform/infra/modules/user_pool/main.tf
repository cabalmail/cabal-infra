resource "aws_cognito_user_pool" "users" {
  name                     = "cabal"
  auto_verified_attributes = [ "phone_number" ]
  sms_configuration {
    external_id    = "${data.aws_caller_identity.current.account_id}_DgEGa1t3qz"
    sns_caller_arn = aws_iam_role.users.arn
  }
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_phone_number"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_client" "users" {
  name         = "cabal_admin_client"
  user_pool_id = aws_cognito_user_pool.users.id
  explicit_auth_flows = [ "USER_PASSWORD_AUTH" ]
}

# auth sufficient pam_exec.so expose_authtok /usr/bin/cognito.bash