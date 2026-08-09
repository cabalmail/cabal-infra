/**
* Pinned threat-protection responses (identity plan Phase 2.5). Without
* this resource, flipping advanced_security_mode to ENFORCED would act
* on whatever Cognito's default automatic responses happen to be; with
* it, ENFORCED behavior is deterministic and provably safe for the
* password-only service accounts.
*
* Actions were chosen against six weeks of prod audit events
* (2026-07-23 analysis):
*
* - Account takeover low = NO_ACTION: the master SMTP-submission
*   account trips Low routinely (rotating Lambda egress IPs look like
*   credential stuffing); acting on Low would harass the mail path for
*   no signal.
* - Account takeover medium/high = MFA_IF_CONFIGURED: enrolled users
*   (every human, enforced by the require_admin_mfa gates) get a TOTP
*   challenge; accounts with no factor are allowed through. This is
*   deliberately not BLOCK: master recorded a real Medium in prod, and
*   a blocked master breaks outbound send. The residual gap - a
*   high-risk sign-in against a no-MFA account is allowed - is
*   confined to the exempt service accounts, and every High still
*   trips the cabal-cognito-high-risk-signin alarm.
* - Compromised credentials = BLOCK: fires only when the password
*   appears in a breach corpus. Humans with breached passwords should
*   be stopped; the service accounts use long random passwords that
*   cannot appear there.
*
* notify_configuration is deliberately omitted (and notify = false
* below): it would require an SES-verified sender identity, and this
* stack deliberately carries no SES. The provider's website doc claims
* the block is required; the provider schema (risk_configuration.go)
* marks it Optional - trust the schema.
*
* No client_id, so the configuration applies pool-wide. Inert while
* advanced_security_mode is AUDIT; it defines what ENFORCED does when
* var.threat_protection_enforced flips.
*/
resource "aws_cognito_risk_configuration" "users" {
  user_pool_id = aws_cognito_user_pool.users.id

  account_takeover_risk_configuration {
    actions {
      low_action {
        event_action = "NO_ACTION"
        notify       = false
      }
      medium_action {
        event_action = "MFA_IF_CONFIGURED"
        notify       = false
      }
      high_action {
        event_action = "MFA_IF_CONFIGURED"
        notify       = false
      }
    }
  }

  compromised_credentials_risk_configuration {
    actions {
      event_action = "BLOCK"
    }
  }
}
