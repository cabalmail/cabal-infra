/**
* Creates a DynamoDB table as a source of truth for users' email addresses.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "addresses" {
  name         = "cabal-addresses"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "address"

  attribute {
    name = "address"
    type = "S"
  }
  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = true
  }
}

/**
* Per-user webmail preferences (theme, accent, density). One row per Cognito
* username. Written by the set_preferences Lambda on user change with client-
* side debounce; read by get_preferences on app load.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "user_preferences" {
  name         = "cabal-user-preferences"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user"

  attribute {
    name = "user"
    type = "S"
  }
  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = true
  }
}

/**
* Per-user, per-domain deny list for address creation. The presence of a
* (user, domain) row means the user is NOT permitted to create addresses on
* that apex domain. The absence of a row is the default and permits creation,
* preserving legacy behavior. Written by the admin set_user_domain_access
* Lambda; read by the new and new_address_admin Lambdas to gate creation, and
* by list_my_domains so the React client can filter its domain picker.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "user_domain_access" {
  name         = "cabal-user-domain-access"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user"
  range_key    = "domain"

  attribute {
    name = "user"
    type = "S"
  }
  attribute {
    name = "domain"
    type = "S"
  }
  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = true
  }
}