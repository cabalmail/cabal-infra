/**
* Creates a Cognito User Pool for authentication against the management application and for authentication at the OS level (providing IMAP and SMTP authentication).
*/

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