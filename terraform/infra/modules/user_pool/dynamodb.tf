/**
* Creates a DynamoDB table as system of record for user properties and preferences.
*/

resource "aws_dynamodb_table" "users" {
  name         = "users"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "username"

  attribute {
    name = "username"
    type = "S"
  }
}

resource "aws_dynamodb_table_item" "seed" {
  table_name = aws_dynamodb_table.users.name
  hash_key   = "username"
  item       = <<ITEM
{
  "username": {"S": "seed"},
  "osid": {"N": "65535"}
  "enabled": {"BOOL": "false"}
}
ITEM
}
