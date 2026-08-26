/**
* set_rules write-latency alarm (user-mail-rules plan, Phase 5.2). The
* editors auto-save the whole rule set on a 300ms debounce, so a slow PUT
* is directly visible as editor jank ("Saving..." lingering) on every
* keystroke pause; the plan sets the p99 budget at one second. The other
* rules alarms (compiler self-test, skip anomaly, outbound burst) live
* with the imap tier's log group in modules/ecs/rules_alarms.tf.
*
* Shaped after modules/call/alarms.tf but standalone: that module's opt-in
* latency alarm is tuned to the 29s timeout ceiling for the message-list
* endpoints, while this one watches a 1s interactivity budget. The
* FunctionName matches the `set_rules` key in local.lambdas - the call
* module deploys each function under its bare key name.
*
* alarm_actions is intentionally unset, matching every other alarm in this
* stack (no notification channel while monitoring is disabled; see
* modules/call/alarms.tf for the full rationale).
*/
resource "aws_cloudwatch_metric_alarm" "set_rules_duration_p99" {
  alarm_name        = "cabal-set_rules-duration-p99"
  alarm_description = "p99 duration of the set_rules Lambda exceeds the 1s interactivity budget - the editors' debounced auto-save is visibly lagging. Look at DynamoDB write latency on cabal-user-rules and the audit-table/SNS side effects."

  namespace   = "AWS/Lambda"
  metric_name = "Duration"
  dimensions = {
    FunctionName = "set_rules"
  }

  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1000 # milliseconds
  unit                = "Milliseconds"

  # No saves in a window == no latency == healthy.
  treat_missing_data = "notBreaching"
}
