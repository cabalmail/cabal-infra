resource "aws_cognito_user" "master" {
  user_pool_id = var.user_pool_id
  username     = "master"
  enabled      = true
  password     = random_password.password.result
  attributes   = {
    osid = 9999
  }
}
