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
/**
* RSS reader tables (docs/1.x/rss-implementation-plan.md, phase 1). Five
* tables: shared canonical feeds, their items, per-user subscriptions and
* folders, and per-user per-item state. Nothing reads or writes them until
* phase 2 (fetcher) and phase 3 (API) land; phase 1 is the schema only.
*
* Shared vs per-user: a public feed has ONE feed row and ONE set of item
* rows no matter how many users subscribe; every per-user fact (folder,
* display preferences, read/favorite state) lives in its own table keyed by
* Cognito username. A credentialed feed gets its own per-user feed row
* (owner_key = the subscriber), so private content never lands in a row
* another user can read.
*
* GSIs project KEYS_ONLY unless a note says otherwise: the table keys ride
* along for free, callers BatchGet the rows they need, and item bodies
* (which can run to hundreds of KB) are never duplicated into an index.
*/

/**
* One row per canonical feed. `due_shard` is "active" while the feed is
* fetchable and is REMOVED when the feed dead-letters (20 consecutive
* failures), which drops the row out of the sparse by_due index the
* scheduler queries; the whole row is deleted when its last subscriber
* leaves. `owner_key` is the subscriber's username for a credentialed feed
* and a fixed sentinel for a shared one, so (canonical_url, owner_key) is a
* uniform dedup lookup - GSIs reject a null range key.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "rss_feed" {
  name                        = "cabal-rss-feed"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "feed_id"
  deletion_protection_enabled = true

  attribute {
    name = "feed_id"
    type = "S"
  }
  attribute {
    name = "canonical_url"
    type = "S"
  }
  attribute {
    name = "owner_key"
    type = "S"
  }
  attribute {
    name = "due_shard"
    type = "S"
  }
  attribute {
    name = "next_fetch_at"
    type = "S"
  }

  global_secondary_index {
    name            = "by_canonical"
    hash_key        = "canonical_url"
    range_key       = "owner_key"
    projection_type = "KEYS_ONLY"
  }
  global_secondary_index {
    name            = "by_due"
    hash_key        = "due_shard"
    range_key       = "next_fetch_at"
    projection_type = "KEYS_ONLY"
  }

  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = true
  }
}

/**
* One row per item per feed. `sort_key` is "<published_at_iso>#<item_id>",
* fixed at first sight so a re-publish updates attributes and never moves
* the row. `fetched_key` is "<fetched_at_iso>#<item_id>" - the since-cursor
* clients sync on, because publishers backdate items and a cursor over
* published_at would miss them. `guid` falls back to the item link, then a
* content hash, when the feed omits one. Bodies over ~300 KB spill to the
* rss-cache bucket (content_s3_key) to stay inside the 400 KB item limit.
*
* The NEW_IMAGE stream drives the rss_notify Lambda (phase 8): an INSERT is
* a new item to fan out to notification-on subscribers, so the stream is the
* durable pending-notification queue and no separate table is needed.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "rss_item" {
  name                        = "cabal-rss-item"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "feed_id"
  range_key                   = "sort_key"
  deletion_protection_enabled = true

  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  attribute {
    name = "feed_id"
    type = "S"
  }
  attribute {
    name = "sort_key"
    type = "S"
  }
  attribute {
    name = "guid"
    type = "S"
  }
  attribute {
    name = "fetched_key"
    type = "S"
  }

  global_secondary_index {
    name            = "by_guid"
    hash_key        = "feed_id"
    range_key       = "guid"
    projection_type = "KEYS_ONLY"
  }
  global_secondary_index {
    name            = "by_fetched"
    hash_key        = "feed_id"
    range_key       = "fetched_key"
    projection_type = "KEYS_ONLY"
  }

  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = true
  }
}

/**
* One row per (user, subscription). `folder_key` is
* "<folder_id>#<subscription_id>" so by_user_folder lists a folder's
* subscriptions in one Query. `notify_feed_id` is set to the feed_id ONLY
* while notifications are enabled and removed otherwise, which makes
* by_feed_notify a sparse index of exactly the subscribers to fan a new
* item out to. by_user_folder projects ALL: subscription rows are small
* and the folder view wants every display attribute without a second read.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "rss_subscription" {
  name                        = "cabal-rss-subscription"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "user"
  range_key                   = "subscription_id"
  deletion_protection_enabled = true

  attribute {
    name = "user"
    type = "S"
  }
  attribute {
    name = "subscription_id"
    type = "S"
  }
  attribute {
    name = "folder_key"
    type = "S"
  }
  attribute {
    name = "notify_feed_id"
    type = "S"
  }

  global_secondary_index {
    name            = "by_user_folder"
    hash_key        = "user"
    range_key       = "folder_key"
    projection_type = "ALL"
  }
  global_secondary_index {
    name            = "by_feed_notify"
    hash_key        = "notify_feed_id"
    range_key       = "user"
    projection_type = "KEYS_ONLY"
  }

  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = true
  }
}

/**
* One row per (user, folder). Hierarchy is by parent_folder_id attribute
* (null = root); a user's whole tree is one Query on the hash key, which is
* how every client loads it, so no index is needed.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "rss_folder" {
  name                        = "cabal-rss-folder"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "user"
  range_key                   = "folder_id"
  deletion_protection_enabled = true

  attribute {
    name = "user"
    type = "S"
  }
  attribute {
    name = "folder_id"
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
* Per-user per-item read/favorite state. `user_feed` is "<user>#<feed_id>"
* and `sort_key` matches the item table's, so a feed's items and one user's
* state for them sort identically and zip together. Rows are created lazily
* on the first mark-read or favorite; a missing row means unread and not
* favorite. Unread is therefore COMPUTED (items minus read rows above the
* subscription's read watermark), never indexed - a never-touched item has
* no row to index. Favorite IS indexed: `favorite_key` is set to sort_key
* only while is_favorite is true, giving a sparse index of exactly the
* favorites. Change order is indexed too: every write sets `updated_key`
* ("<updated_at>#<item_id>", unique per row), and `by_updated` is what the
* state-sync form of /rss_list_items pages so a mark made on one device
* reaches the others. Rows written before the key existed are picked up by
* that sync's initial full pull of the partition, never by the index.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "rss_user_item_state" {
  name                        = "cabal-rss-user-item-state"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "user_feed"
  range_key                   = "sort_key"
  deletion_protection_enabled = true

  attribute {
    name = "user_feed"
    type = "S"
  }
  attribute {
    name = "sort_key"
    type = "S"
  }
  attribute {
    name = "favorite_key"
    type = "S"
  }
  attribute {
    name = "updated_key"
    type = "S"
  }

  global_secondary_index {
    name            = "favorite_by_feed"
    hash_key        = "user_feed"
    range_key       = "favorite_key"
    projection_type = "KEYS_ONLY"
  }

  # Rows are a few flags; projecting them saves the state sync a BatchGet.
  global_secondary_index {
    name            = "by_updated"
    hash_key        = "user_feed"
    range_key       = "updated_key"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = true
  }
}
