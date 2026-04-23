# ── Shared-secret parameter for the alert_sms webhook ──────────
#
# The value is random at first apply; rotate by re-running with
# `terraform taint random_password.alert_secret` (manual for Phase 1).
#
# Callers (e.g. Uptime Kuma) send this value in the X-Alert-Secret
# header; the Lambda compares it with hmac.compare_digest.

resource "random_password" "alert_secret" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "alert_secret" {
  name        = "/cabal/alert_sms_secret"
  description = "Shared secret for the alert_sms Lambda webhook. Rotate manually."
  type        = "SecureString"
  value       = random_password.alert_secret.result

  lifecycle {
    ignore_changes = [value]
  }
}
