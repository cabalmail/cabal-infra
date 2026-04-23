/**
* Phase 1 monitoring & alerting stack: SMS sink Lambda plus Uptime Kuma.
*
* Components:
*   - SNS alerts topic with SMS subscriptions per on-call phone number.
*   - SSM `SecureString` parameter holding the shared webhook secret.
*   - `alert_sms` Lambda: universal webhook sink that authenticates callers
*     by shared secret and publishes to SNS (critical) or SES (warning).
*   - Uptime Kuma ECS service, EFS-backed for SQLite state.
*   - Public ALB with Cognito authenticate-oidc action in front of Kuma,
*     accessible at uptime.<control-domain>.
*
* This module is deployed only when `var.monitoring = true` at the root.
* The phone-number verification SMS path added in 0.5.0 uses a separate
* SNS topic; disabling this module does not affect user-visible SMS.
*/

data "aws_caller_identity" "current" {}
