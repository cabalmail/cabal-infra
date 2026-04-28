# ── Phase 4 §2: log-derived CloudWatch metric filters ──────────
#
# CloudWatch metric filters scan log lines as they arrive and emit a
# custom metric in the `Cabalmail/Logs` namespace. cloudwatch_exporter
# scrapes those metrics; Prometheus alerts on the rates. This is the
# "stay on CloudWatch Logs" path described in docs/monitoring.md §21.
#
# Why log-derived metrics, not exporters: Sendmail's log format is
# not what postfix_exporter expects, and a per-tier sidecar exporter
# pass would force a destructive change to every mail-tier task
# definition (see docs/0.7.0/monitoring-plan.md §6 on stable-flag
# discipline). Metric filters skip both problems and add zero new
# moving parts in the data path.
#
# All filters emit to the same metric name across tiers (no per-tier
# dimension). cloudwatch_exporter sums them; the alert rule is on
# aggregate. The runbook tells the operator how to identify the
# offending tier when an alert fires.
#
# The fail2ban filter is intentionally NOT here: as of 0.7.0,
# `[program:fail2ban]` is commented out in every mail-tier
# supervisord.conf. A filter today would publish flat-zero forever
# and mask the disabled state. Re-add when fail2ban is re-enabled.

locals {
  # Match "stat=Deferred" anywhere in the line. Sendmail emits this on
  # any temporary delivery failure (4xx dsn, queue retry pending).
  pattern_sendmail_deferred = "\"stat=Deferred\""

  # Match any 5.x.y dsn — sendmail's permanent-failure indicator. The
  # pattern is a substring match for "dsn=5"; in real sendmail logs
  # the field is always followed by `.N.M`, so false positives
  # (e.g. message-id containing "dsn=5") are negligible.
  pattern_sendmail_bounced = "\"dsn=5\""

  # Dovecot login failures. The two-term pattern requires both
  # substrings on the same line; matches "Aborted login (auth failed,
  # ...)" and similar.
  pattern_imap_auth_failed = "\"imap-login\" \"auth failed\""
}

# ── Sendmail Deferred (3 mail tiers → one metric) ──────────────

resource "aws_cloudwatch_log_metric_filter" "sendmail_deferred" {
  for_each = var.tier_log_group_names

  name           = "cabal-sendmail-deferred-${each.key}"
  log_group_name = each.value
  pattern        = local.pattern_sendmail_deferred

  metric_transformation {
    name          = "SendmailDeferred"
    namespace     = "Cabalmail/Logs"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# ── Sendmail Bounced (3 mail tiers → one metric) ──────────────

resource "aws_cloudwatch_log_metric_filter" "sendmail_bounced" {
  for_each = var.tier_log_group_names

  name           = "cabal-sendmail-bounced-${each.key}"
  log_group_name = each.value
  pattern        = local.pattern_sendmail_bounced

  metric_transformation {
    name          = "SendmailBounced"
    namespace     = "Cabalmail/Logs"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# ── IMAP auth failures (imap tier only) ────────────────────────

resource "aws_cloudwatch_log_metric_filter" "imap_auth_failures" {
  name           = "cabal-imap-auth-failures"
  log_group_name = var.tier_log_group_names["imap"]
  pattern        = local.pattern_imap_auth_failed

  metric_transformation {
    name          = "IMAPAuthFailures"
    namespace     = "Cabalmail/Logs"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}
