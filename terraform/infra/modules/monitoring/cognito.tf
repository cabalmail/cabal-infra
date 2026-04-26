# ── Cognito app client for ALB authenticate-oidc action ────────
#
# The existing user pool client (`cabal_admin_client`) is configured for
# USER_PASSWORD_AUTH only; ALB needs an OAuth client with a hosted UI
# callback. This client is scoped to the Kuma UI specifically.

resource "aws_cognito_user_pool_client" "kuma" {
  name                                 = "cabal_uptime_client"
  user_pool_id                         = var.user_pool_id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = [
    "https://uptime.${var.control_domain}/oauth2/idpresponse"
  ]
  logout_urls = [
    "https://uptime.${var.control_domain}/"
  ]

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
}

resource "aws_cognito_user_pool_client" "healthchecks" {
  name                                 = "cabal_heartbeat_client"
  user_pool_id                         = var.user_pool_id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = [
    "https://heartbeat.${var.control_domain}/oauth2/idpresponse"
  ]
  logout_urls = [
    "https://heartbeat.${var.control_domain}/"
  ]

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
}
