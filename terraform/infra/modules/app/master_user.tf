resource "aws_cognito_user" "master" {
  user_pool_id = var.user_pool_id
  username     = "master"
  enabled      = true
  password     = random_password.password.result
  attributes   = {
    osid = 9999
  }
}

resource "aws_cognito_user_in_group" "master_admin" {
  user_pool_id = var.user_pool_id
  group_name   = var.admin_group_name
  username     = aws_cognito_user.master.username
}
