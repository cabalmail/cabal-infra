# monitoring

Phases 1, 2, 3, and the first wave of Phase 4 of the 0.7.0 monitoring & alerting stack.

Deployed only when `var.monitoring = true` at the root module. See
`docs/0.7.0/monitoring-plan.md` for the overall design and
`docs/monitoring.md` for the operator runbook.

## What this module creates

- SSM `SecureString` parameters:
  - `/cabal/alert_sink_secret` — shared webhook secret (auto-generated
    on first apply; `ignore_changes` so rotation sticks).
  - `/cabal/pushover_user_key` — operator populates after creating a
    Pushover account.
  - `/cabal/pushover_app_token` — operator populates after creating the
    Cabalmail Pushover application.
  - `/cabal/ntfy_publisher_token` — operator populates after
    bootstrapping the ntfy admin user.
- `alert_sink` Lambda fronted by a Lambda Function URL. Authenticates
  callers with the shared secret in `X-Alert-Secret`. Routes by
  severity: `critical` → Pushover priority 1 + ntfy priority 5,
  `warning` → ntfy priority 3, `info` → drop.
- Self-hosted ntfy ECS service (one task, EFS-backed cache + auth DB
  at access point `/ntfy`).
- Uptime Kuma ECS service (one task, EFS-backed SQLite at access point
  `/uptime-kuma`).
- Shared public ALB:
  - Default action → Kuma, fronted by Cognito authenticate-oidc.
  - Host-header rule on `ntfy.<control-domain>` → ntfy (no ALB auth;
    ntfy enforces its own token auth).
- Route 53 records `uptime.<control-domain>` and `ntfy.<control-domain>`.

## Post-apply manual steps (Phase 1)

See `docs/monitoring.md` for detailed steps. Summary:

1. Create a Pushover account + Cabalmail application; put the user key
   and application token into the SSM parameters above.
2. Open an ECS Exec session into the ntfy task; run
   `ntfy user add --role=admin admin` and `ntfy token add admin`; put
   the returned token into `/cabal/ntfy_publisher_token`.
3. Install the Pushover and ntfy mobile apps on the on-call phone; log
   in to ntfy with the admin credentials and subscribe to the `alerts`
   topic.
4. Open `https://uptime.<control-domain>/` (Cognito login), create the
   Kuma admin account, add the Phase 1 monitor set, and wire the
   Webhook notification provider to the `alert_sink_function_url`.

## Acceptance (Phase 1)

- Breaking a health check on dev (e.g. temporarily blocking port 993)
  produces a Pushover **and** ntfy push within ~2 min.
- Kuma's recovery notification sends a follow-up push.
- `https://uptime.<control-domain>/` is reachable only after Cognito login.
- `https://ntfy.<control-domain>/` rejects anonymous requests with 401.

## What this module adds in Phase 3

- Cloud Map private DNS namespace `cabal-monitoring.cabal.internal`
  with one service per metrics component (Prometheus uses it for
  scrape-target discovery).
- Prometheus ECS service (TSDB on EFS access point `/prometheus`,
  config and rules baked into `docker/prometheus/`).
- Alertmanager ECS service (state on EFS access point
  `/alertmanager`). Posts to the existing `alert_sink` Lambda for both
  critical and warning severities; uses Authorization Bearer for the
  shared secret. The Lambda accepts both `X-Alert-Secret` (Phase 1/2)
  and `Authorization: Bearer` (Phase 3) headers.
- Grafana ECS service (sqlite on EFS access point `/grafana`),
  reachable at `https://metrics.<control-domain>/` behind a new
  Cognito client. Datasource and four dashboards baked in via
  provisioning.
- Three exporters as ECS services:
  - `cloudwatch_exporter` — single task pulling Lambda, DynamoDB, EFS,
    ECS, ApiGateway, ApplicationELB, CertificateManager, Cognito.
  - `blackbox_exporter` — single task for synthetic HTTP/TCP probes.
  - `node_exporter` — DaemonSet (one per cluster instance) with host
    `/proc` and `/sys` bind-mounts and `network_mode = host` so it
    reports the EC2 host's metrics, not the container's.
- New ALB listener rule on `metrics.<control-domain>` (priority 120)
  with its own Cognito client.
- New SSM `SecureString` `/cabal/grafana_admin_password` (auto-generated
  on first apply; `ignore_changes` so rotation sticks).

The Phase 3 plan also calls for tier-specific exporters (dovecot,
postfix, opendkim) as sidecars in the mail-tier task definitions.
These are intentionally deferred — see `docs/monitoring.md` §
"Phase 3 — deferred items" for the rationale.

## Acceptance (Phase 3)

- `https://metrics.<control-domain>/` is reachable only after Cognito login.
- All four provisioned dashboards exist under the **Cabalmail** folder.
- `cloudwatch_exporter` and `node_exporter` targets are `up` in Prometheus.
- A tightened threshold rule produces a ntfy push via Alertmanager →
  `alert_sink` within ~5 min.

## What Phase 4 §1 + §4 + §5 add

Phase 4's first wave is mostly docs, alert-rule annotations, and a single
SSM parameter — no new ECS services. The shippable units:

- **Runbooks** for every Phase 1-3 alert in `docs/operations/runbooks/`,
  indexed by [`README.md`](../../../../docs/operations/runbooks/README.md).
- **`runbook_url` annotations** on every rule in
  [`docker/prometheus/rules/alerts.yml`](../../../../docker/prometheus/rules/alerts.yml).
  Alertmanager forwards them; the `alert_sink` Lambda surfaces them on
  Pushover (tap-action `url`) and ntfy (`Click` header).
- **Static runbook map** in
  [`lambda/api/alert_sink/function.py`](../../../../lambda/api/alert_sink/function.py)
  (`_RUNBOOK_MAP`) for sources that can't carry `runbook_url` in their
  webhook body — Kuma monitors and Healthchecks checks. Update the keys
  if you rename a monitor or check.
- **`quarterly-review` Healthchecks check** — a 90-day operator-driven
  heartbeat. New SSM parameter `/cabal/healthcheck_ping_quarterly_review`
  in [`ssm.tf`](./ssm.tf). The runbook documents what the review
  entails.
- **"Stay on CloudWatch Logs" decision** captured in
  [`docs/monitoring.md`](../../../../docs/monitoring.md) §21. Phase 4 §2
  (log-derived metrics + alerts) follows in a later ship.

The remaining Phase 4 work — IaC for Kuma + Healthchecks config (§3) —
ships separately. See
[`docs/0.7.0/monitoring-plan.md`](../../../../docs/0.7.0/monitoring-plan.md)
§"Phase 4: Logs + Tuning" for the roadmap.

## Acceptance (Phase 4 first wave)

- Every Prometheus rule has a `runbook_url` annotation that resolves to
  a markdown file under `docs/operations/runbooks/`.
- `_RUNBOOK_MAP` covers every Kuma monitor name in
  [`docs/monitoring.md`](../../../../docs/monitoring.md) §9 and every
  Healthchecks check in §12.
- A test push from Kuma and from Healthchecks arrives with a tappable
  runbook link.
- `quarterly-review` check exists in Healthchecks and shows green after
  the bootstrap ping documented in
  [`docs/monitoring.md`](../../../../docs/monitoring.md) §22.

## What Phase 4 §2 adds

Log-derived metrics & alerts via CloudWatch metric filters — the
"stay on CloudWatch Logs" path from
[`docs/monitoring.md`](../../../../docs/monitoring.md) §21.

- **CloudWatch metric filters** on the three mail-tier log groups
  (`/ecs/cabal-imap`, `/ecs/cabal-smtp-in`, `/ecs/cabal-smtp-out`)
  emitting to a new `Cabalmail/Logs` namespace. See [`log_metrics.tf`](./log_metrics.tf).
  Three metrics: `SendmailDeferred`, `SendmailBounced`, `IMAPAuthFailures`.
- **cloudwatch_exporter config** scrapes the new namespace —
  [`docker/cloudwatch-exporter/config.yml`](../../../../docker/cloudwatch-exporter/config.yml).
- **Three Prometheus alert rules** in the new `log-derived` group —
  `SendmailDeferredSpike` (warning), `SendmailBouncedSpike` (critical),
  `IMAPAuthFailureSpike` (warning). See
  [`docker/prometheus/rules/alerts.yml`](../../../../docker/prometheus/rules/alerts.yml).
- **`LambdaErrors` regex extended** to `cabal-.+|assign_osid` so the
  Cognito post-confirmation Lambda is covered without a separate
  log-derived metric. See the comment on the rule for the rationale.

The variable `tier_log_group_names` is required as of this phase; root
module passes it from `module.ecs.tier_log_group_names`.

## Acceptance (Phase 4 §2)

- `aws logs describe-metric-filters --log-group-name /ecs/cabal-imap`
  lists `cabal-sendmail-deferred-imap`, `cabal-sendmail-bounced-imap`,
  and `cabal-imap-auth-failures`.
- Prometheus exposes `aws_cabalmail_logs_*_sum` series.
- A synthetic test (12 forged `stat=Deferred` lines into `/ecs/cabal-imap`
  in <1 min) fires `SendmailDeferredSpike` within ~17 min.

## What Phase 4 §3 adds

IaC reconciler for Healthchecks check definitions. Kuma config stays
manual (see [`docs/monitoring.md`](../../../../docs/monitoring.md) §26.3).

- **`cabal-healthchecks-iac` Lambda**, source in
  [`lambda/api/healthchecks_iac/`](../../../../lambda/api/healthchecks_iac/).
  Reads desired checks from `config.py`, upserts via Healthchecks v3
  API on a Cloud Map private DNS name, populates the corresponding
  `/cabal/healthcheck_ping_*` SSM parameters from the API response.
- **Cloud Map registration for Healthchecks** —
  [`discovery.tf`](./discovery.tf) adds `healthchecks` to
  `local.monitoring_services`; [`healthchecks.tf`](./healthchecks.tf)
  registers the ECS service.
- **`cabal-healthchecks-iac` SG** allows egress on 8000 to the
  Healthchecks task SG, plus 53/udp for VPC Resolver and 443/tcp for
  SSM/CloudWatch APIs.
- **`/cabal/healthchecks_api_key` SSM parameter** —
  [`ssm.tf`](./ssm.tf). Placeholder; operator seeds via UI key creation
  + `aws ssm put-parameter`.
- **`aws_lambda_invocation` resource** with `lifecycle_scope = "CRUD"`
  and trigger on `source_code_hash` re-invokes whenever
  `config.py` changes.

The Lambda gracefully no-ops (returns `status: skipped`) when the API
key is still placeholder, so first apply doesn't fail before the
operator bootstraps the key.

## Acceptance (Phase 4 §3)

- After API key bootstrap, `aws lambda invoke --function-name
  cabal-healthchecks-iac /tmp/out.json` returns `status: ok` with
  `reconciled = 6`.
- All six `/cabal/healthcheck_ping_*` SSM parameters populated with
  real ping URLs (not placeholders).
- Editing `config.py` and re-running the build pipeline + Terraform
  re-invokes the Lambda automatically.
