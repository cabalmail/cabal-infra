'''Declarative Healthchecks check configuration.

Each entry is upserted by the healthchecks_iac Lambda against the
Healthchecks instance fronted by heartbeat.<control-domain>. Keys map
1:1 to the Healthchecks v3 API; see https://healthchecks.io/docs/api/.

Notes:
- `ssm_param`: name of the SSM parameter to populate with this check's
  ping URL after upsert. Consumers (Lambdas, the reconfigure loop) read
  this parameter at cold start and ping it on success. The Lambda only
  writes when the value differs from what's in SSM (no churn).
- Integrations (notification channels) are NOT managed here. The
  operator creates one Webhook integration in the UI per the procedure
  in docs/monitoring.md §13 and assigns it to all checks. The API key
  this Lambda uses cannot create channels via the v3 API.
- Removing a check from this list does NOT delete it in Healthchecks.
  The Lambda logs a warning. This is deliberate — accidental config
  drops shouldn't silently take down heartbeats. Delete via the UI.
- Severity is implicit: every Healthchecks "down" event posts to the
  alert_sink Lambda as `severity: critical`. To make an individual
  check less severe (e.g. dmarc-ingest is benign when missed), the
  operator currently has to override on the Healthchecks integration
  body — see the runbook for that check.
'''

# Time helpers: Healthchecks expects timeout/grace as seconds.
_MIN = 60
_HOUR = 60 * _MIN
_DAY = 24 * _HOUR

CHECKS = [
    {
        'name': 'certbot-renewal',
        'kind': 'simple',
        'timeout': 60 * _DAY,
        'grace': 24 * _HOUR,
        'desc': 'cabal-certbot-renewal Lambda. Runs every 60 days via EventBridge Scheduler.',
        'tags': ['cabalmail', 'lambda', 'certs'],
        'ssm_param': '/cabal/healthcheck_ping_certbot_renewal',
    },
    {
        'name': 'aws-backup',
        'kind': 'simple',
        'timeout': 1 * _DAY,
        'grace': 6 * _HOUR,
        'desc': 'AWS Backup daily plan. Pinged by cabal-backup-heartbeat off EventBridge.',
        'tags': ['cabalmail', 'backup'],
        'ssm_param': '/cabal/healthcheck_ping_aws_backup',
    },
    {
        'name': 'dmarc-ingest',
        'kind': 'simple',
        'timeout': 6 * _HOUR,
        'grace': 2 * _HOUR,
        'desc': 'cabal-process-dmarc Lambda. Diagnostic only; missed pings are benign.',
        'tags': ['cabalmail', 'lambda', 'dmarc'],
        'ssm_param': '/cabal/healthcheck_ping_dmarc_ingest',
    },
    {
        'name': 'ecs-reconfigure',
        'kind': 'simple',
        'timeout': 30 * _MIN,
        'grace': 30 * _MIN,
        'desc': 'reconfigure.sh loop in mail-tier containers. Pings on each successful regenerate.',
        'tags': ['cabalmail', 'ecs', 'mail-tier'],
        'ssm_param': '/cabal/healthcheck_ping_ecs_reconfigure',
    },
    {
        'name': 'cognito-user-sync',
        'kind': 'simple',
        'timeout': 30 * _DAY,
        'grace': 7 * _DAY,
        'desc': 'assign_osid post-confirmation Lambda. Fires only on user signup; loose grace.',
        'tags': ['cabalmail', 'lambda', 'auth'],
        'ssm_param': '/cabal/healthcheck_ping_cognito_user_sync',
    },
    {
        'name': 'quarterly-review',
        'kind': 'simple',
        'timeout': 90 * _DAY,
        'grace': 14 * _DAY,
        'desc': 'Operator-driven 90-day monitoring review. Manual ping after the runbook.',
        'tags': ['cabalmail', 'manual'],
        'ssm_param': '/cabal/healthcheck_ping_quarterly_review',
    },
]
