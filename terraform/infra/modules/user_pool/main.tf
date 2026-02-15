/**
* Creates a Cognito User Pool for authentication against the management application and for authentication at the OS level (providing IMAP and SMTP authentication).
*/

resource "aws_cognito_user_pool" "users" {
  name  = "cabal"
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

resource "aws_cognito_user_pool_client" "users" {
  name                  = "cabal_admin_client"
  user_pool_id          = aws_cognito_user_pool.users.id
  explicit_auth_flows   = [ "USER_PASSWORD_AUTH" ]
  access_token_validity = 12
  id_token_validity     = 12
}
