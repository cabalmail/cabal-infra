/**
* Creates a DynamoDB table as a source of truth for users' email addresses.
*/

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "addresses" {
  name           = "cabal-addresses"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "address"

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