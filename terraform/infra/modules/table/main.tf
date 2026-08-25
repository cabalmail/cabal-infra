/**
* Creates a DynamoDB table as a source of truth for users' email addresses.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "addresses" {
  name                        = "cabal-addresses"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "address"
  deletion_protection_enabled = true

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
  name                        = "cabal-user-preferences"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "user"
  deletion_protection_enabled = true

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

# No deletion protection here, alone among the tables: every row is a
# TTL-reaped 60-second rate-limit window, so there is no data worth
# protecting and the flag would only add friction to a teardown.
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
* APNs device tokens for push notifications (docs/0.11.0/push-notifications.md).
* One row per (Cognito username, device token); a user with an iPhone and an
* iPad has two rows. Written by the push_register / push_deregister Lambdas;
* read (Query on `user`) and pruned (on APNs Unregistered/BadDeviceToken) by
* push_dispatch. Rows are re-created by the app on every launch, so the data
* is fully reconstructible and deliberately outside the backup plan (matching
* cabal-user-preferences).
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "push_tokens" {
  name                        = "cabal-push-tokens"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "user"
  range_key                   = "device_token"
  deletion_protection_enabled = true

  attribute {
    name = "user"
    type = "S"
  }
  attribute {
    name = "device_token"
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
* Per-user, per-domain allow list for address creation. The presence of a
* (user, domain) row means the user IS permitted to create addresses on that
* apex domain; the absence of a row defaults to deny. This matches the
* expected scaling pattern (many users, many vanity apexes, each user using a
* small subset). Written by the admin set_user_domain_access Lambda; read by
* the new and new_address_admin Lambdas to gate creation, and by
* list_my_domains so the React client can filter its domain picker.
*/

/**
* Per-user mail rules (docs/1.x/user-mail-rules-plan.md). One row per Cognito
* username holding the whole ordered rule set as a JSON-encoded array (array
* index = precedence), plus a monotonic version for optimistic concurrency.
* Written whole-row by the set_rules Lambda; read by get_rules on client load
* and scanned by the IMAP tier's procmail compiler on reconfigure (Phase 2).
* Bounded: <= 100 rules of ~1 KB each, well inside the 400 KB item limit.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "user_rules" {
  name                        = "cabal-user-rules"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "user"
  deletion_protection_enabled = true

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
* Audit trail for mail-rule writes (docs/1.x/user-mail-rules-plan.md). One row
* per set_rules PUT: (user, ts) -> {version, diff}, where diff is a JSON Patch
* against the prior rule set. Kept for operator incident response (who set the
* rule that caused a mail loop, and what it said); TTL-pruned at 90 days via
* expiresAt.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "user_rules_audit" {
  name                        = "cabal-user-rules-audit"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "user"
  range_key                   = "ts"
  deletion_protection_enabled = true

  attribute {
    name = "user"
    type = "S"
  }
  attribute {
    name = "ts"
    type = "N"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = true
  }
}

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "user_domain_access" {
  name                        = "cabal-user-domain-access"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "user"
  range_key                   = "domain"
  deletion_protection_enabled = true

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