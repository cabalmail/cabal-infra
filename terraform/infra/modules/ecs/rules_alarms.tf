/**
* Mail-rules observability alarms (user-mail-rules plan, Phase 5.2) — the
* always-on path while the Grafana/monitoring stack is disabled. The
* compiler on the imap tier emits embedded-metric-format lines into the
* tier's log group (namespace Cabal/UserRules; see
* docker/shared/compile-user-rules.py `emf`), and the two log metric
* filters below derive the signals the compiler cannot emit itself: a
* self-test failure aborts container start before any EMF line, and the
* per-submission outbound signal lives in the forward-drain daemon's log
* lines.
*
* alarm_actions is intentionally unset on all of these, matching the
* Cognito risk alarm in the user_pool module and the Lambda latency alarms
* in app/modules/call: monitoring is disabled project-wide so this account
* has no notification channel, and a CloudWatch alarm cannot publish to an
* SNS topic on the AWS-managed key. The alarms still enter ALARM state and
* are observable via the console and describe-alarms.
*/

# -- Compiler self-test failures ---------------------------------------
#
# compile-user-rules-selftest.py gates both the image build and container
# start (prepare-sendmail.sh runs it before /run/sendmail-ready, so a
# failure holds sendmail down and ECS replaces the task). The runtime
# failure prints one unambiguous line to the tier log; count those. A
# regressed compiler shows up here as a task crash-loop that would
# otherwise only be visible as ECS churn.

resource "aws_cloudwatch_log_metric_filter" "rules_selftest_failures" {
  name           = "cabal-rules-selftest-failures"
  log_group_name = aws_cloudwatch_log_group.tier["imap"].name
  # Quoted term = literal match (brackets are pattern syntax otherwise).
  pattern = "\"[compile-user-rules-selftest] FAIL\""

  metric_transformation {
    name      = "RuleCompilerSelfTestFailures"
    namespace = "Cabal/UserRules"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "rules_selftest_failures" {
  alarm_name        = "cabal-rules-selftest-failures"
  alarm_description = "The mail-rules compiler failed its golden-file self-test at imap container start. The task will not come healthy (sendmail is held down) and ECS will replace it; deliveries continue on the previous task. A compiler regression shipped - roll back the imap image."

  namespace   = "Cabal/UserRules"
  metric_name = "RuleCompilerSelfTestFailures"

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1

  # No failures logged == healthy; without this the alarm would sit in
  # INSUFFICIENT_DATA between (rare) container starts.
  treat_missing_data = "notBreaching"
}

# -- Skipped-rule anomaly ----------------------------------------------
#
# The compiler skips individual rules for benign reasons (a deleted
# destination folder, a not-yet-picked one), so a static threshold would
# either flap or miss. What we care about is the plan's "10x baseline"
# signal - a schema change or compiler bug suddenly skipping rules that
# compiled yesterday - which is what an anomaly band expresses natively.
# The 900s period matches the reconfigure cadence (SNS-triggered plus the
# 15-minute fallback), so each datapoint is roughly one compile run.

resource "aws_cloudwatch_metric_alarm" "rules_skipped_anomaly" {
  alarm_name        = "cabal-rules-skipped-anomaly"
  alarm_description = "The mail-rules compiler is skipping far more rules than its recent baseline across two consecutive runs. If this follows a deploy, a schema or compiler change likely broke rules that previously compiled - check compile_skip_rule reasons in the imap tier log."

  comparison_operator = "GreaterThanUpperThreshold"
  threshold_metric_id = "band"
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "skips"
    return_data = true
    metric {
      namespace   = "Cabal/UserRules"
      metric_name = "SkippedRules"
      period      = 900
      stat        = "Sum"
    }
  }

  metric_query {
    id          = "band"
    expression  = "ANOMALY_DETECTION_BAND(skips, 10)"
    label       = "SkippedRules (expected band)"
    return_data = true
  }
}

# -- Outbound submission rate (forward/reply loop indicator) -----------
#
# Rule-driven forwards and auto-replies both leave through the
# /var/spool/cabal-forward drain, which logs one "forwarded for" line per
# submission - the only per-send signal visible in the container log (the
# reply helper's own suppression messages land in the per-user procmail
# log on EFS, which the log driver never sees). The per-user guards
# (7-day vacation cache, 100/24h reply cap, X-Loop stamps, per-message
# forward cap) should keep this trickle-slow, so a sustained burst means
# a loop the guards missed. Informational: threshold is a heuristic set
# well above legitimate use, not a precise cap.

resource "aws_cloudwatch_log_metric_filter" "rules_outbound_submissions" {
  name           = "cabal-rules-outbound-submissions"
  log_group_name = aws_cloudwatch_log_group.tier["imap"].name
  pattern        = "\"[cabal-forward-drain] forwarded for\""

  metric_transformation {
    name      = "OutboundRuleSubmissions"
    namespace = "Cabal/UserRules"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "rules_outbound_burst" {
  alarm_name        = "cabal-rules-outbound-burst"
  alarm_description = "Rule-driven forwards/auto-replies are leaving the imap tier at a sustained burst rate - a possible mail loop the per-user guards missed. Identify the user in the [cabal-forward-drain] log lines, then disable or fix the offending rule (set_rules audit table shows who changed what)."

  namespace   = "Cabal/UserRules"
  metric_name = "OutboundRuleSubmissions"

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 30

  treat_missing_data = "notBreaching"
}
