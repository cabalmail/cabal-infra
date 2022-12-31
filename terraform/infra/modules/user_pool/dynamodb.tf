/**
* Creates a DynamoDB table as system of record for user properties and preferences.
*/

resource "aws_dynamodb_table" "counter" {
  name         = "cabal-counter"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "counter"

  attribute {
    name = "counter"
    type = "S"
  }
}

resource "aws_dynamodb_table_item" "seed" {
  table_name = aws_dynamodb_table.counter.name
  hash_key   = "counter"
  item       = jsonencode({
    counter = { S    = "counter" }
    osid    = { N    = "65535" }
    enabled = { BOOL = false }
  })
  lifecycle {
    ignore_changes = [item]
  }
}
