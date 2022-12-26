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

  attribute {
    name = "osid"
    type = "N"
  }
  
  attribute {
    name = "enabled"
    type = "BOOL"
  }

  global_secondary_index {
    name               = "counter-index"
    write_capacity     = 5
    read_capacity      = 5
    projection_type    = "ALL"
    key_schema {
      attribute_name = "osid"
      key_type       = "HASH"
    }
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
