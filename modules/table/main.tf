resource "aws_dynamodb_table" "cabal_addresses_table" {
  name           = "cabal-addresses"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "address"
  
  # global_secondary_index {
  #   name               = "usernameIndex"
  #   hash_key           = "username"
  #   write_capacity     = 5
  #   read_capacity      = 5
  #   projection_type    = "ALL"
  # }

  attribute {
    name = "address"
    type = "S"
  }

  # attribute {
  #   name = "username"
  #   type = "S"
  # }
}