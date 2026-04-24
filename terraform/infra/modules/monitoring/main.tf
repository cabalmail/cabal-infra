/**
* Phase 1 monitoring & alerting stack: alert_sink Lambda, self-hosted ntfy,
* and Uptime Kuma.
*
* Components:
*   - SSM `SecureString` parameters for the webhook shared secret, Pushover
*     user key + app token, and the ntfy publisher bearer token.
*   - `alert_sink` Lambda: universal webhook sink that authenticates callers
*     by shared secret and fans out to Pushover (critical) and ntfy
*     (critical + warning). Severity `info` is dropped.
*   - ntfy ECS service (one task, EFS-backed cache + auth DB), reachable at
*     ntfy.<control-domain> via a host-header rule on the shared ALB.
*   - Uptime Kuma ECS service (one task, EFS-backed SQLite) at the ALB's
*     default action, behind Cognito authenticate-oidc.
*
* This module is deployed only when `var.monitoring = true` at the root.
* The 0.5.0 phone-verification SMS path uses its own resources and is
* unrelated to this stack.
*/

data "aws_caller_identity" "current" {}
