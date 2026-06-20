/**
* Latency and error alarms for the message-list endpoints (large-mailbox
* hardening plan, Layer 4.3). Opt-in via var.alarm_on_latency so only the
* endpoints whose tail latency tracks folder cardinality (list_messages,
* list_envelopes) carry them.
*
* The Lambda timeout is 29s (matched to API Gateway's integration timeout in
* lambda.tf), so a real timeout is now an alarmable signal rather than billing
* invisibly past a client failure: it surfaces as Duration near the ceiling and
* an Errors increment. The p99 alarm is the leading indicator (latency creeping
* toward the ceiling); the Errors alarm catches the actual failures, timeouts
* included.
*
* alarm_actions is intentionally unset, matching the Cognito risk alarm in the
* user_pool module: monitoring is disabled project-wide so this account has no
* notification channel, and a CloudWatch alarm cannot publish to an SNS topic
* on the AWS-managed key (it needs a customer-managed KMS key granting
* cloudwatch.amazonaws.com kms:Decrypt/GenerateDataKey). Wiring a delivery
* target is a deliberate follow-up; until then the alarms are observable via
* the console and describe-alarms and still enter ALARM state.
*/

resource "aws_cloudwatch_metric_alarm" "duration_p99" {
  count = var.alarm_on_latency ? 1 : 0

  alarm_name        = "cabal-${var.name}-duration-p99"
  alarm_description = "p99 duration of the ${var.name} Lambda is approaching the 29s API Gateway/Lambda timeout - large-folder requests are running long. Investigate folder cardinality and IMAP latency."

  namespace   = "AWS/Lambda"
  metric_name = "Duration"
  dimensions = {
    FunctionName = aws_lambda_function.api_call.function_name
  }

  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 25000 # milliseconds; the function caps at 29000
  unit                = "Milliseconds"

  # No invocations in a window == no latency == healthy. Without this the alarm
  # would sit in INSUFFICIENT_DATA whenever the endpoint is idle.
  treat_missing_data = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  count = var.alarm_on_latency ? 1 : 0

  alarm_name        = "cabal-${var.name}-errors"
  alarm_description = "The ${var.name} Lambda returned an error (a timeout at the 29s ceiling counts here). On the message-list path this usually means an IMAP request outran the integration timeout on a large folder."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions = {
    FunctionName = aws_lambda_function.api_call.function_name
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1

  treat_missing_data = "notBreaching"
}
