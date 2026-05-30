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
* Per-caller rate-limit counters for admin mutations (Phase 5 of
* docs/0.10.x/application-surface-hardening-plan.md). One row per
* (caller, 60-second window): the partition key is "<caller>#<window-id>" and a
* TTL on expires_at reaps spent windows. Written and read by the admin mutation
* Lambdas via _shared/admin_limits.py. On-demand billing; the access pattern is
* a single hot key per active admin per minute.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "rate_limits" {
  name         = "cabal-rate-limits"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = true
  }
}

/**
* Per-user, per-domain allow list for address creation. The presence of a
* (user, domain) row means the user IS permitted to create addresses on that
* apex domain; the absence of a row defaults to deny. This matches the
* expected scaling pattern (many users, many vanity apexes, each user using a
* small subset). Written by the admin set_user_domain_access Lambda; read by
* the new and new_address_admin Lambdas to gate creation, and by
* list_my_domains so the React client can filter its domain picker.
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