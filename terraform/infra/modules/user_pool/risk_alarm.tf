/**
* CloudWatch alarm on high-risk sign-ins flagged by Cognito threat protection
* (plan Phase 2). The pool runs advanced_security_mode = "AUDIT", so Cognito
* scores each sign-in and publishes the result to the AWS/Cognito namespace
* without blocking; this alarm surfaces the high-risk ones (impossible travel,
* anomalous device/IP - the adaptive-auth account-takeover signal).
*
* Metric choice: AccountTakeoverRisk carries the RiskLevel dimension, so it can
* be filtered to "high"; the plain "Risk" metric does not and cannot. RiskLevel
* values are lowercase. AccountTakeoverRisk publishes one stream per Operation
* (SignIn, SignUp, PasswordChange); this alarm watches SignIn, the operation
* the plan's impossible-travel scenario describes. High-risk SignUp and
* PasswordChange would each be a parallel alarm if we decide to watch them too.
*/
resource "aws_cloudwatch_metric_alarm" "cognito_high_risk_signin" {
  alarm_name        = "cabal-cognito-high-risk-signin"
  alarm_description = "Cognito threat protection flagged a high-risk sign-in (adaptive auth). Audit mode, so the sign-in was not blocked - investigate the account."

  namespace   = "AWS/Cognito"
  metric_name = "AccountTakeoverRisk"
  dimensions = {
    UserPoolId = aws_cognito_user_pool.users.id
    Operation  = "SignIn"
    RiskLevel  = "high"
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1

  # No data == no high-risk sign-ins == healthy. Without this the alarm would
  # sit in INSUFFICIENT_DATA whenever the (sparse) metric stream has gaps.
  treat_missing_data = "notBreaching"

  # alarm_actions is intentionally unset. This account has no security-alert
  # notification channel (monitoring is disabled project-wide), and a
  # CloudWatch alarm cannot publish to an SNS topic encrypted with the
  # AWS-managed key - it needs a customer-managed KMS key whose policy grants
  # cloudwatch.amazonaws.com kms:Decrypt/GenerateDataKey. Wiring a delivery
  # target (topic + CMK + subscription) is a deliberate follow-up; until then
  # the alarm is observable via the console and describe-alarms and still
  # enters ALARM state on a high-risk sign-in.
}
