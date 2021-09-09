resource "aws_dynamodb_table" "cabal_addresses_table" {
  name           = "cabal-addresses"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "address"
  
  attribute {
    name = "address"
    type = "S"
  }

  attribute {
    name = "address"
    type = "S"
  }

  attribute {
    name = "subdomain"
    type = "S"
  }

  attribute {
    name = "comment"
    type = "S"
  }

  attribute {
    name = "tld"
    type = "S"
  }

  attribute {
    name = "user"
    type = "S"
  }

  attribute {
    name = "username"
    type = "S"
  }

  attribute {
    name = "RequestTime"
    type = "S"
  }

  attribute {
    name = "zone-id"
    type = "S"
  }

  ttl {
    attribute_name = "TimeToExist"
    enabled        = false
  }
}