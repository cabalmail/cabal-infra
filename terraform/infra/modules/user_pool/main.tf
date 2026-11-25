/**
* Creates a Cognito User Pool for authentication against the management application and for authentication at the OS level (providing IMAP and SMTP authentication).
*/

locals {
  # SMS is on only when a 10DLC campaign registration id has been supplied.
  # A brand-new deploy has no such id (an approved campaign is a
  # weeks-of-carrier-review post-bootstrap step), so SMS starts off and the
  # pool must not require phone verification - otherwise Cognito falls
  # through to the shared SNS sandbox and signup fails with no user-facing
  # remediation. See issue #712 and docs/sms-10dlc.md.
  sms_enabled = var.ten_dlc_campaign_registration_id != ""

  # The attributes users may set on their own record, at SignUp and later
  # through UpdateUserAttributes: what the clients' sign-up forms and
  # React's VerifyEmail gate send. Every app client in this module that
  # issues tokens to users or their apps uses this list; every other
  # attribute is set by the pool's triggers or by admin calls. A client
  # that starts writing another attribute adds it here. Keep it non-empty:
  # Cognito doesn't document an empty list as "none", and its default for
  # a client with no list is wider.
  user_write_attributes = ["email", "phone_number", "preferred_username"]
}

resource "aws_cognito_user_pool" "users" {
  name = "cabal"
  # Email joins phone (identity-iam-hardening plan Phase 1): a verified email
  # is the recovery fallback that survives a lost or rotated phone, and it is
  # SMS-independent, so it is collected and verified even before a 10DLC
  # campaign exists. Auto-verify only applies when the attribute is present
  # at signup, so email-less signups keep working unchanged. Verification
  # emails go out via Cognito's default sender (COGNITO_DEFAULT, 50/day) -
  # plenty at invite-gated scale and avoids taking on SES.
  auto_verified_attributes   = local.sms_enabled ? ["email", "phone_number"] : ["email"]
  sms_verification_message   = local.sms_enabled ? "Your Cabalmail verification code is {####}." : null
  sms_authentication_message = local.sms_enabled ? "Your Cabalmail verification code is {####}." : null

  # Brand the emails Cognito sends (signup confirmation, attribute
  # verification, password reset) to match the SMS template. The sender
  # stays no-reply@verificationemail.com - that is fixed for the
  # COGNITO_DEFAULT email service; only SES would change it.
  verification_message_template {
    email_subject = "Your Cabalmail verification code"
    email_message = "Your Cabalmail verification code is {####}."
  }

  dynamic "sms_configuration" {
    for_each = local.sms_enabled ? [1] : []
    content {
      sns_caller_arn = aws_iam_role.users.arn
      external_id    = "cabal-cognito-sms"
    }
  }

  # TOTP second factor, opt-in (Phase 1). OPTIONAL means no challenge fires
  # until a user enrolls, so this is inert until the clients grow enrollment
  # UX and SOFTWARE_TOKEN_MFA challenge handling - do not flip to ON/required
  # (or add the require_admin_mfa trigger) before both clients handle the
  # challenge, or the first enrollee locks themselves out of the apps. TOTP
  # is SMS-independent, so it is available regardless of local.sms_enabled.
  mfa_configuration = "OPTIONAL"
  software_token_mfa_configuration {
    enabled = true
  }

  # Email first, phone second (Phase 1): a SIM swap alone can no longer take
  # over an account whose email is verified, and a lost phone is no longer a
  # permanent lockout. The phone mechanism exists only when SMS is on. With
  # SMS off this replaces the previous admin_only setting: operationally
  # equivalent while users have no verified email (the operator resets via
  # AdminSetUserPassword either way), and self-serve recovery starts working
  # by itself as users verify email addresses.
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
    dynamic "recovery_mechanism" {
      for_each = local.sms_enabled ? [1] : []
      content {
        name     = "verified_phone_number"
        priority = 2
      }
    }
  }

  schema {
    name                     = "osid"
    attribute_data_type      = "Number"
    developer_only_attribute = false
    mutable                  = true
    required                 = false
    number_attribute_constraints {
      min_value = 2000
    }
  }
  lambda_config {
    post_confirmation    = aws_lambda_function.assign_osid.arn
    pre_sign_up          = aws_lambda_function.check_invite.arn
    pre_token_generation = aws_lambda_function.require_admin_mfa.arn
  }

  # Threat protection requires the Plus feature plan; on the default
  # ESSENTIALS tier, UpdateUserPool rejects the add-on below with
  # FeatureUnavailableInTierException. Plus bills $0.02/MAU from the first
  # user (Essentials has a 10k-MAU free allowance, Plus has none), so this
  # line is where the pool starts costing money - a deliberate decision.
  user_pool_tier = "PLUS"

  # Cognito threat protection (plan Phase 2.5): AUDIT scores sign-in risk
  # (impossible travel, compromised credentials) and surfaces it in
  # CloudWatch without blocking; ENFORCED lets Cognito act on it - MFA
  # challenge for enrolled users, outright block for high-risk sign-ins
  # with no second factor. Promote per environment only after (1) the
  # AccountTakeoverRisk metrics have soaked clean and (2) TOTP enrollment
  # is real there, or a false positive locks out an un-enrolled user.
  user_pool_add_ons {
    advanced_security_mode = var.threat_protection_enforced ? "ENFORCED" : "AUDIT"
  }
}

# AWS End User Messaging 10DLC number used by the SNS SMS path. Created
# only once the account's 10DLC campaign registration is approved and
# its id is supplied; requesting a number against an unapproved or
# absent campaign fails.
#
# Create waits for the number to reach ACTIVE, which for 10DLC includes
# the carrier-side campaign/number association; usually minutes, but if
# it exceeds the timeout the apply fails with the number left tainted -
# re-apply rather than releasing it by hand.
#
# The HELP/STOP/START keyword auto-responses on this number must match
# the messages registered with the campaign; the provider has no keyword
# resource, so a post-apply step (put-sms-keywords.sh in infra.yml)
# owns them.
resource "aws_pinpointsmsvoicev2_phone_number" "ten_dlc" {
  count                       = var.ten_dlc_campaign_registration_id != "" ? 1 : 0
  iso_country_code            = "US"
  message_type                = "TRANSACTIONAL"
  number_capabilities         = ["SMS"]
  number_type                 = "TEN_DLC"
  registration_id             = var.ten_dlc_campaign_registration_id
  deletion_protection_enabled = true

  timeouts {
    create = "30m"
  }
}

resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.users.id
  description  = "Administrators with access to user management"
}

resource "aws_cognito_user_pool_client" "users" {
  name                = "cabal_admin_client"
  user_pool_id        = aws_cognito_user_pool.users.id
  explicit_auth_flows = ["USER_PASSWORD_AUTH"]

  write_attributes = local.user_write_attributes

  access_token_validity  = 12
  id_token_validity      = 12
  refresh_token_validity = 7
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Bound a stolen/leaked refresh token to 7 days of exposure instead of the
  # 30-day default. enable_token_revocation defaults to true, but state it so
  # admin-user-global-sign-out reliably invalidates issued tokens.
  enable_token_revocation = true
}

# Hosted-UI domain prefix used by the ALB authenticate-oidc action in the
# monitoring module. Creating it here (singleton per pool) lets it exist
# even when `var.monitoring = false` - inexpensive and avoids the need
# to destroy-and-recreate it when monitoring is toggled.
resource "aws_cognito_user_pool_domain" "users" {
  domain       = "cabal-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.users.id
}

# Public OAuth client for the browser extension
# (docs/1.x/browser-extension-plan.md, Phase 3.2): Hosted UI + PKCE code
# flow, no client secret (an extension cannot keep one). Two kinds of
# callback URL: the always-registered /extension-auth page on the admin
# origin (the tab-based flow Safari uses, since it has no WebExtensions
# identity API — the page is provisioned in modules/app/s3.tf), plus the
# Chrome identity-API redirects from var.extension_redirect_uris, which
# embed extension IDs the operator supplies once they exist.
resource "aws_cognito_user_pool_client" "extension" {
  name         = "cabal_extension_client"
  user_pool_id = aws_cognito_user_pool.users.id

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls = concat(
    ["https://admin.${var.control_domain}/extension-auth"],
    var.extension_redirect_uris,
  )
  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  # The extension writes no attributes; the shared list keeps this client
  # from granting more than cabal_admin_client does.
  write_attributes = local.user_write_attributes

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 7
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Same rationale as cabal_admin_client above.
  enable_token_revocation = true
}

# OAuth sign-in for the read-only MCP server (docs/agent-access.md,
# "Connect claude.ai"). claude.ai's custom connectors cannot send a static
# Authorization header, so instead of a minted cbl_agt_ token the user signs
# in here, through the Hosted UI, and claude.ai holds a Cognito access token
# that /mcp's authorizer accepts.
#
# The resource server defines the scopes that token carries. mail.read is
# what Phase A grants: read-only, INBOX-only (the folder limit is enforced by
# authorize_agent and the mcp Lambda, not by the scope string). mail.flag adds
# one write on top of it: adding the user's own custom flags (palette slots)
# to messages, through the MCP add_flag tool; authorize_agent maps a token
# carrying both to the read_flag access level. A short
# identifier rather than the MCP URL keeps the access token small; resource
# binding (RFC 8707) needs managed login, which this pool's domain does not
# use, so the identifier does not have to match the URL.
resource "aws_cognito_resource_server" "mcp" {
  identifier   = local.mcp_resource_server_identifier
  name         = "Cabalmail MCP"
  user_pool_id = aws_cognito_user_pool.users.id

  scope {
    scope_name        = local.mcp_read_scope_name
    scope_description = "Read mail in the folders the MCP server allows (INBOX), without changing it"
  }

  scope {
    scope_name        = local.mcp_flag_scope_name
    scope_description = "Add your own custom flags to mail in those folders; nothing else"
  }
}

locals {
  mcp_resource_server_identifier = "cabal-mcp"
  mcp_read_scope_name            = "mail.read"
  mcp_flag_scope_name            = "mail.flag"

  # The only redirect URI the hosted Claude apps (claude.ai, Desktop, mobile)
  # use for a custom connector's OAuth flow. Claude Code uses a loopback
  # redirect on a random port, which Cognito's exact-match callback list
  # cannot express, so Claude Code keeps using a minted token.
  mcp_oauth_callback_urls = ["https://claude.ai/api/mcp/auth_callback"]
}

# Public OAuth client for claude.ai: authorization-code flow with PKCE, no
# client secret (the user enters only the client id when adding the
# connector), Hosted UI sign-in with the user's own Cabalmail login and TOTP.
# Its tokens carry the mail.read and mail.flag scopes and nothing else - no openid, no
# aws.cognito.signin.user.admin - so they cannot call Cognito's user APIs, and
# the REST API's Cognito-authorized routes, which expect an ID token, refuse
# them.
resource "aws_cognito_user_pool_client" "mcp" {
  name         = "cabal_mcp_client"
  user_pool_id = aws_cognito_user_pool.users.id

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = aws_cognito_resource_server.mcp.scope_identifiers
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = local.mcp_oauth_callback_urls
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]

  # The connector writes no attributes; the shared list keeps this client
  # from granting more than cabal_admin_client does.
  write_attributes = local.user_write_attributes

  # authorize_agent verifies the access token locally and cannot see a
  # Cognito revocation, so the access token's lifetime is the longest a
  # revoked sign-in keeps working: fifteen minutes. claude.ai refreshes ahead
  # of expiry. The refresh token matches the browser extension's, the other
  # public client in this pool; after a week the user signs in again.
  # Refresh-token rotation is not on: Cognito requires the client to give up
  # ALLOW_REFRESH_TOKEN_AUTH for it, and the extension client sets the
  # precedent for a public client without it.
  access_token_validity  = 15
  id_token_validity      = 15
  refresh_token_validity = 7
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  enable_token_revocation       = true
  prevent_user_existence_errors = "ENABLED"
}
