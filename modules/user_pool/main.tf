resource "aws_cognito_user_pool" "cabal_pool" {
  name                     = "cabal"
  alias_attributes         = [ "preferred_username" ]
  auto_verified_attributes = [ "phone_number" ]
  schema {
    name                     = "preferred_username"
    attribute_data_type      = "String"
    developer_only_attribute = false
    mutable                  = false
    required                 = true
    string_attribute_constraints {
      min_length = 1
      max_length = 24
    }
  }
  schema {
    name                     = "phone_number"
    attribute_data_type      = "String"
    developer_only_attribute = false
    mutable                  = true
    required                 = true
    string_attribute_constraints {
      min_length = 10
      max_length = 24
    }
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
}