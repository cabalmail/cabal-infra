# ── SSM parameters for the alert_sink Lambda ───────────────────
#
# alert_secret: shared secret callers (Kuma, Alertmanager) send in the
# X-Alert-Secret header. Generated at first apply; rotate via
# `terraform taint random_password.alert_secret`.
#
# pushover_user_key / pushover_app_token: obtained after creating a
# Pushover account and application. Terraform seeds placeholders; the
# operator populates real values out-of-band with `aws ssm put-parameter`.
# `ignore_changes = [value]` prevents subsequent applies from overwriting.
#
# ntfy_publisher_token: obtained via `ntfy token add admin` against the
# running ntfy container (see docs/monitoring.md). Same placeholder +
# ignore_changes pattern.

resource "random_password" "alert_secret" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "alert_secret" {
  name        = "/cabal/alert_sink_secret"
  description = "Shared secret for the alert_sink Lambda webhook. Rotate manually."
  type        = "SecureString"
  value       = random_password.alert_secret.result

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "pushover_user_key" {
  name        = "/cabal/pushover_user_key"
  description = "Pushover user key. Populate after creating a Pushover account."
  type        = "SecureString"
  value       = "placeholder-set-via-aws-ssm-put-parameter"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "pushover_app_token" {
  name        = "/cabal/pushover_app_token"
  description = "Pushover application API token. Populate after creating the Cabalmail Pushover application."
  type        = "SecureString"
  value       = "placeholder-set-via-aws-ssm-put-parameter"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "ntfy_publisher_token" {
  name        = "/cabal/ntfy_publisher_token"
  description = "ntfy bearer token with publish access to the alerts topic. Populate after bootstrapping the ntfy container."
  type        = "SecureString"
  value       = "placeholder-set-via-aws-ssm-put-parameter"

  lifecycle {
    ignore_changes = [value]
  }
}

# ── Healthchecks Django secret key ─────────────────────────────
#
# Generated at first apply. Rotate via `terraform taint
# random_password.healthchecks_secret_key` (will invalidate active
# sessions on the Healthchecks UI).

resource "random_password" "healthchecks_secret_key" {
  length  = 50
  special = false
}

resource "aws_ssm_parameter" "healthchecks_secret_key" {
  name        = "/cabal/healthchecks_secret_key"
  description = "Django SECRET_KEY for the Healthchecks ECS service. Rotate via terraform taint."
  type        = "SecureString"
  value       = random_password.healthchecks_secret_key.result

  lifecycle {
    ignore_changes = [value]
  }
}

# ── Healthcheck ping URLs (Phase 2 heartbeats) ─────────────────
#
# One placeholder per scheduled job. After Healthchecks is up, the
# operator creates a check per job in the UI and pastes its ping URL
# into the corresponding parameter with `aws ssm put-parameter
# --overwrite`. Consumers (Lambdas, reconfigure.sh, GH Actions) read
# the value at invocation time and skip the ping if the value still
# starts with "placeholder-".

locals {
  heartbeat_jobs = {
    certbot_renewal   = "Daily certbot renewal Lambda."
    aws_backup        = "Daily AWS Backup completion (DynamoDB + EFS)."
    dmarc_ingest      = "Hourly DMARC report ingestion Lambda (process_dmarc)."
    ecs_reconfigure   = "ECS reconfigure loop in the mail tier containers."
    cognito_user_sync = "Cognito post-confirmation Lambda (assign_osid)."
  }
}

resource "aws_ssm_parameter" "healthcheck_ping" {
  for_each = local.heartbeat_jobs

  name        = "/cabal/healthcheck_ping_${each.key}"
  description = "Healthchecks ping URL for ${each.value} Populate after creating the corresponding check in the Healthchecks UI."
  type        = "SecureString"
  value       = "placeholder-set-via-aws-ssm-put-parameter"

  lifecycle {
    ignore_changes = [value]
  }
}
