resource "aws_cognito_user_pool" "cabal_pool" {
  name = "cabal"
}

resource "aws_cognito_user_pool_client" "cabal_pool_client" {
  name         = "cabal_admin_client"
  user_pool_id = aws_cognito_user_pool.cabal_pool.id
}