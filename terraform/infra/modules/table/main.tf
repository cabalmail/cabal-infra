resource "aws_dynamodb_table" "addresses" {
  name           = "cabal-addresses"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "address"

  attribute {
    name = "address"
    type = "S"
  }

}