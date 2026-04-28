# monitoring

Optional monitoring and alerting stack for the 0.7.0 release. Deployed only when `var.monitoring = true` at the root module. See [docs/0.7.0/monitoring-plan.md](../../../../docs/0.7.0/monitoring-plan.md) for the design rationale and [docs/monitoring.md](../../../../docs/monitoring.md) for the operator runbook.

## What this module creates

### SSM SecureString parameters

All managed with `ignore_changes = [value]` so out-of-band rotation sticks:

- `/cabal/alert_sink_secret` -- shared webhook secret (auto-generated on first apply).
- `/cabal/pushover_user_key`, `/cabal/pushover_app_token` -- operator populates from the Pushover account + application.
- `/cabal/ntfy_publisher_token` -- operator populates after bootstrapping the ntfy admin user.
- `/cabal/healthchecks_secret_key` -- Django `SECRET_KEY` (auto-generated, rotatable via `terraform taint`).
- `/cabal/healthchecks_api_key` -- v3 read-write API key for the IaC Lambda. Operator creates in the UI and seeds.
- `/cabal/healthcheck_ping_*` -- six placeholders, populated automatically by the IaC Lambda after the API key is seeded.
- `/cabal/grafana_admin_password` -- Grafana local-admin password (auto-generated, `ignore_changes` so rotation sticks).

### Lambdas

- `alert_sink` -- universal webhook sink fronted by a Lambda Function URL. Authenticates callers with `X-Alert-Secret` (Kuma, Healthchecks) or `Authorization: Bearer` (Alertmanager). Routes by severity: `critical` -> Pushover priority 1 + ntfy priority 5, `warning` -> ntfy priority 3, `info` -> drop. Translates Alertmanager's native webhook v4 body into the `{severity, summary, source, runbook_url}` shape expected downstream. Surfaces runbook URLs as Pushover tap-action `url` and ntfy `Click` header.
- `cabal-backup-heartbeat` -- invoked by EventBridge on AWS Backup `JOB_COMPLETED` events; pings the corresponding Healthchecks check.
- `cabal-healthchecks-iac` -- reconciles Healthchecks check definitions from [`lambda/api/healthchecks_iac/config.py`](../../../../lambda/api/healthchecks_iac/config.py) against the running instance. Auto-invoked by Terraform when the Lambda's `source_code_hash` changes (i.e. when `config.py` is edited). Returns `status: skipped` when the API key is still placeholder so first apply doesn't fail before bootstrap. Reaches the Healthchecks API via the private Cloud Map A record; the API key in SSM is sufficient auth.

### ECS services

All services share the existing ECS cluster:

- `cabal-uptime-kuma` -- Uptime Kuma (one task, EFS-backed SQLite at access point `/uptime-kuma`).
- `cabal-ntfy` -- self-hosted ntfy (one task, EFS-backed cache + auth DB at access point `/ntfy`).
- `cabal-healthchecks` -- self-hosted Healthchecks (one task, EFS SQLite at `/healthchecks`).
- `cabal-prometheus` -- Prometheus TSDB on EFS at `/prometheus` (uid/gid 65534).
- `cabal-alertmanager` -- silences and notification log on EFS at `/alertmanager`.
- `cabal-grafana` -- Grafana SQLite on EFS at `/grafana` (uid/gid 472). Mounts at `/grafana-data` to dodge the dockerd copy-up chown gotcha.
- `cabal-cloudwatch-exporter`, `cabal-blackbox-exporter` -- single-task Prometheus exporters.
- `cabal-node-exporter` -- DAEMON service (one task per cluster instance), `network_mode = "host"`.

### ALB and DNS

- Shared public ALB:
  - Default action -> Kuma, fronted by Cognito `authenticate-oidc`.
  - Host-header rule on `ntfy.<control-domain>` -> ntfy (no ALB auth; ntfy enforces its own token auth).
  - Host-header rule on `heartbeat.<control-domain>` -> Healthchecks (Cognito).
  - Host-header rule on `metrics.<control-domain>` -> Grafana (Cognito, separate client).
- Route 53 records for `uptime`, `ntfy`, `heartbeat`, `metrics` in both the public zone and the VPC private zone (the private zone shadows the public zone for the control domain, so VPC-internal callers can't resolve unless we mirror).

### Cloud Map

- Private DNS namespace `cabal-monitoring.cabal.internal` with one service per metrics component. Prometheus uses DNS-SD `type: A` queries against the awsvpc-mode services and `type: SRV` against `node-exporter` (host-mode tasks can't register A records).
- The IaC Lambda reaches Healthchecks via `healthchecks.cabal-monitoring.cabal.internal:8000`, bypassing the Cognito-fronted ALB.

### CloudWatch metric filters

Three filters per mail tier, emitting to a `Cabalmail/Logs` namespace:

- `cabal-sendmail-deferred-{tier}` matching `"stat=Deferred"` -> `SendmailDeferred` metric.
- `cabal-sendmail-bounced-{tier}` matching `"dsn=5"` -> `SendmailBounced` metric.
- `cabal-imap-auth-failures` (imap tier only) matching `"imap-login" "auth failed"` -> `IMAPAuthFailures` metric.

cloudwatch_exporter scrapes these as `aws_cabalmail_logs_*_sum`; Prometheus rules in the `log-derived` group of [`docker/prometheus/rules/alerts.yml`](../../../../docker/prometheus/rules/alerts.yml) alert on the rates.

### Prometheus alert rules

Defined in [`docker/prometheus/rules/alerts.yml`](../../../../docker/prometheus/rules/alerts.yml), grouped by domain (aws-services, blackbox, platform, log-derived). Every rule carries a `runbook_url` annotation that resolves to a markdown file under [`docs/operations/runbooks/`](../../../../docs/operations/runbooks/). Alertmanager forwards the annotation; the alert_sink Lambda surfaces it as a tappable link.

## Variables

| Variable | Required | Notes |
| --- | --- | --- |
| `control_domain` | yes | Used to derive the four hostnames (`uptime`, `ntfy`, `heartbeat`, `metrics`). |
| `region` | yes | AWS region. |
| `vpc_id`, `vpc_cidr_block`, `public_subnet_ids`, `private_subnet_ids` | yes | VPC inputs. |
| `zone_id`, `private_zone_id` | yes | Public + private hosted zones for the control domain. |
| `cert_arn` | yes | ACM cert ARN for `*.<control-domain>`. |
| `ecs_cluster_id`, `ecs_cluster_capacity_provider`, `efs_id` | yes | Cluster + EFS inputs. |
| `tier_log_group_names` | yes | Map of mail-tier CloudWatch log group names from `module.ecs.tier_log_group_names`; metric filters target these. |
| `*_ecr_repository_url` | yes | ECR URLs for every image the module deploys. |
| `image_tag` | yes | Same image tag the mail tiers use; sourced from `/cabal/deployed_image_tag`. |
| `environment` | yes | Used as a Prometheus external label. |
| `user_pool_id`, `user_pool_arn`, `user_pool_domain` | yes | Cognito inputs for the `authenticate-cognito` actions. |
| `lambda_bucket` | yes | S3 bucket holding the Lambda zips built by `build-api.sh`. |
| `mail_domains` | yes | First entry is used as the From: domain for Healthchecks-originated mail. |
| `ntfy_topic` | no | Default `alerts`. |
| `healthchecks_registration_open` | no | Default `false`. Flip to `true` for the bootstrap signup, then back. |

## Operational notes

- **First-time enable**: build images first (Docker workflow), then apply Terraform. Without the images present, ECS keeps the new services pending. See [docs/monitoring.md](../../../../docs/monitoring.md) step 3 for the full procedure.
- **EFS state survives stack disable**: setting `var.monitoring = false` cleanly destroys the ECS services, ALB, Lambdas, and SSM parameters, but leaves the EFS access-point directories. Re-enabling picks up the existing state. ECR repositories also persist (cheap, not flag-gated).
- **Kuma config stays manual**: Kuma exposes only a Socket.IO API in this release. Building IaC around Socket.IO is fragile across Kuma upgrades and offers little value for the eight monitors. The monitor set is documented in [docs/monitoring.md](../../../../docs/monitoring.md) step 10. Revisit when Kuma ships a stable REST API ([louislam/uptime-kuma#1170](https://github.com/louislam/uptime-kuma/issues/1170)).
- **`_RUNBOOK_MAP` is hand-maintained**: a static dict in [`alert_sink/function.py`](../../../../lambda/api/alert_sink/function.py) maps Kuma monitor names and Healthchecks check names to runbook URLs. Renaming a monitor or check without updating the map drops the runbook link from its push. PRs that change one without the other should fail review.
- **fail2ban metrics deferred**: `[program:fail2ban]` is currently commented out in every mail-tier `supervisord.conf`. Add a metric filter for it when fail2ban is re-enabled.
