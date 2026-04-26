# Monitoring & Alerting Plan

## Context

Cabalmail has been stable in production, but the pace of AI-assisted development has increased the risk of regressions slipping into production. The 0.5.0 admin dashboard introduces SMS as a first-class delivery channel (phone verification). 0.7.0 ("Stabilize") is the right moment to put a monitoring and alerting framework in place that:

- Detects user-visible failures (IMAP/SMTP/HTTPS down, certificates expiring, API errors) before users do.
- Surfaces internal-service degradation (queue depth, mail delivery latency, container restarts, disk pressure on EFS/EC2).
- Catches silent failures of scheduled jobs (certbot renewal, weekly Terraform run, DMARC ingestion, backups).
- Routes alerts through push-notification channels that bypass the Cabalmail email system (so an outage is still reachable), with a Pushover/ntfy dual-send on critical and ntfy-only on warning.

All components must be open source or in-house. The target deployment is the existing ECS EC2 cluster — no new managed services beyond what AWS already provides (CloudWatch). The alerting path deliberately does **not** depend on AWS SNS SMS (provisioning is slow and opaque) or on SES email (can't alert on our own mail outage).

### Alert transports

Two independent push channels, chosen for deliverability and automation-friendliness:

- **Pushover** (critical only) — paid mobile app ($5 one-time per platform) with per-app tokens. Priority-1 pushes bypass quiet hours on the user's phone, which makes it our "wake someone up" channel. Account + application must be created manually once; runbook documents the steps. The application token and user key live in SSM Parameter Store.
- **Self-hosted ntfy** (critical + warning) — open-source push server ([ntfy.sh](https://ntfy.sh)), deployed as a new ECS service on the existing cluster. Uses its own token-based auth (not Cognito) so both the publisher Lambda and the subscriber phone can reach it without an OAuth dance. Exposed at `ntfy.<control-domain>` through a host-header listener rule on the Kuma ALB.

The "universal sink" Lambda (`alert_sink`, formerly `alert_sms`) accepts the same `{severity, source, summary}` webhook payload from every monitoring component and fans out to the transports per the routing table:

| Severity  | Pushover     | ntfy priority | Notes |
| --------- | ------------ | ------------- | ----- |
| critical  | priority 1–2 | 5             | Dual-send for redundancy; Pushover handles DND-bypass, ntfy is the record of the event. |
| warning   | —            | 3             | ntfy only; shows a normal notification, no wake-up. |
| info      | —            | —             | Dropped at the Lambda; available for dashboard annotations only. |

## Approach

Four phases, each independently shippable and useful on its own:

1. **Alert sink + ntfy push service + black-box uptime monitoring** — fastest user-visible win, smallest blast radius.
2. **Heartbeat monitoring for scheduled jobs** — closes the "silent cron" gap.
3. **Metrics stack (Prometheus / Alertmanager / Grafana) with exporters** — depth and trending.
4. **Log aggregation + alert rule tuning** — the long tail.

Each phase ends with a working, alerting system. Phases 2–4 are additive; the project can pause at the end of any phase without leaving the system in an inconsistent state.

---

## Per-Environment Enablement (Feature Flag)

The monitoring stack should not deploy to every environment. Dev needs it sometimes (for validating alert rules), stage usually doesn't need it, prod always does. The `backup` module already establishes the pattern we'll reuse.

### Terraform variable

**`terraform/infra/variables.tf`** — new variable:

```hcl
variable "monitoring" {
  type        = bool
  description = "Whether to deploy the monitoring & alerting stack (Uptime Kuma, ntfy, Healthchecks, Prometheus/Alertmanager/Grafana, alert_sink Lambda). Defaults to false."
  default     = false
}
```

### Module gating

**`terraform/infra/main.tf`** — gate the new module the same way `backup` is gated:

```hcl
module "monitoring" {
  source = "./modules/monitoring"
  count  = var.monitoring ? 1 : 0
  # ...
}
```

Downstream wiring (exporter sidecars in existing mail-tier task definitions, Healthchecks pings in scheduled Lambdas, the `alert_sink` Lambda) all consult `var.monitoring` and no-op when false. Exporter sidecars in ECS task definitions are the one place that needs care — adding/removing a container from a task definition causes a task replacement, so the flag must be stable for a given environment rather than toggled casually.

### CI wiring

**`.github/workflows/terraform.yml`** — add one line to each `terraform.tfvars` generation block, mirroring the existing `backup` line:

```yaml
echo "monitoring = ${{ vars.TF_VAR_MONITORING }}" >> terraform.tfvars
```

### Per-environment values

Set in GitHub Actions environment variables per environment, not in code:

| Environment | `TF_VAR_MONITORING` | Rationale                                       |
| ----------- | ------------------- | ----------------------------------------------- |
| prod        | `true`              | Always on. The whole point of the project.      |
| stage       | `false` by default  | Flip to `true` when actively testing alert flows or rehearsing a prod change. |
| dev         | `false` by default  | Flip to `true` for alert-rule development; flip back when done to save cluster capacity. |

### Granularity trade-off

A single bool is coarse but matches how the system is actually used. Alternatives considered and deferred:

- **Per-phase flags** (`monitoring_uptime`, `monitoring_heartbeats`, etc.) — over-granular; no real use case for enabling Prometheus without Kuma.
- **Per-component flags within the `monitoring` module** — useful for cost tuning later (e.g., skip Grafana if we lean on CloudWatch dashboards), but premature. Revisit if any single component turns out to dominate cost.

### Independence from user-facing SMS

The 0.5.0 phone-verification SMS path uses its own AWS Pinpoint/SNS resources and is unrelated to alerting. The alerting stack does not depend on SMS at all (see [Alert transports](#alert-transports)), so disabling `var.monitoring` has no impact on user-visible SMS.

### Acceptance

- `terraform plan` with `monitoring = false` shows zero resources from the `monitoring` module and no sidecars attached to mail-tier tasks.
- Toggling `monitoring` from `false` → `true` in dev produces a clean apply; toggling back to `false` produces a clean destroy with no orphan resources.
- The phone-verification SMS path in 0.5.0 continues to work in both states.

---

## Golden Signals per Tier

First-pass targets for the four Google SRE golden signals — **latency**, **traffic**, **errors**, **saturation** — for every tier we run. These drive exporter selection in Phase 3 and alert thresholds throughout. Expect every threshold in this table to move at least once after we see real traffic; the numbers below are starting points, not commitments.

Conventions: *p95* unless noted, *over 5 min* unless noted. "—" means the signal exists but we don't alert on it yet (dashboard-only).

### IMAP tier (Dovecot + Sendmail/LDA + Procmail)

| Signal      | Metric                                                          | Starting threshold         | Source                    |
| ----------- | --------------------------------------------------------------- | -------------------------- | ------------------------- |
| Latency     | IMAP command p95 response time                                  | > 1 s for 10 min → warn    | `dovecot_exporter`        |
| Latency     | IMAP TLS handshake from Kuma probe                              | > 3 s for 10 min → warn    | Kuma / `blackbox_exporter`|
| Traffic     | Active IMAP connections, logins/min                             | — (dashboard)              | `dovecot_exporter`        |
| Errors      | Auth failure rate (excluding known bot IPs)                     | > 20%/5 min → warn         | Dovecot log → metric      |
| Errors      | Local delivery (LDA) failures                                   | > 1%/5 min → critical      | sendmail log → metric     |
| Errors      | IMAP port 993 probe failure                                     | 2 consecutive fails → crit | Kuma                      |
| Saturation  | Host CPU / memory                                               | > 85% for 15 min → warn    | `node_exporter`           |
| Saturation  | EFS mailstore used bytes, BurstCreditBalance                    | credits < 20% for 1h → warn| `cloudwatch_exporter`     |
| Saturation  | Open file descriptors on dovecot process                        | > 80% of ulimit → warn     | `node_exporter` / procfs  |

### SMTP-IN tier (Sendmail inbound relay)

| Signal      | Metric                                                          | Starting threshold          | Source                   |
| ----------- | --------------------------------------------------------------- | --------------------------- | ------------------------ |
| Latency     | Inbound message time-in-queue p95                               | > 60 s for 10 min → warn    | `postfix_exporter`       |
| Traffic     | Inbound messages/min, connections/min                           | — (dashboard)               | `postfix_exporter`       |
| Errors      | SMTP 5xx rejects (non-spam)                                     | > 2%/10 min → warn          | sendmail log → metric    |
| Errors      | Local delivery failures forwarding to IMAP tier                 | > 1%/5 min → critical       | sendmail log → metric    |
| Errors      | Port 25 probe failure                                           | 2 consecutive fails → crit  | Kuma                     |
| Saturation  | Sendmail mqueue depth                                           | > 50 for 15 min → warn, > 500 → crit | `postfix_exporter`       |
| Saturation  | Host CPU / memory                                               | > 85% for 15 min → warn     | `node_exporter`          |
| Saturation  | fail2ban active bans                                            | — (dashboard; brute-force signal) | log → metric       |

### SMTP-OUT tier (Sendmail + Dovecot-submission + OpenDKIM)

| Signal      | Metric                                                          | Starting threshold          | Source                    |
| ----------- | --------------------------------------------------------------- | --------------------------- | ------------------------- |
| Latency     | Submission-to-relay time p95                                    | > 30 s for 10 min → warn    | `postfix_exporter`        |
| Latency     | DKIM signing time p95                                           | > 200 ms for 10 min → warn  | `opendkim_exporter`       |
| Traffic     | Submitted messages/min, DKIM-signed msgs/min                    | — (dashboard)               | `postfix_exporter`, opendkim |
| Errors      | Outbound 5xx (remote rejects)                                   | > 5%/30 min → critical      | sendmail log → metric     |
| Errors      | DKIM signing failures                                           | any for 5 min → warn        | `opendkim_exporter` / log |
| Errors      | Submission auth failures (587/465)                              | > 20%/5 min → warn          | Dovecot log → metric      |
| Errors      | Ports 587/465 probe failure                                     | 2 consecutive fails → crit  | Kuma                      |
| Saturation  | Outbound mqueue depth                                           | > 50 for 15 min → warn      | `postfix_exporter`        |
| Saturation  | Host CPU / memory                                               | > 85% for 15 min → warn     | `node_exporter`           |
| Saturation  | Reputation proxy: deferred-due-to-remote-rate-limit count       | sustained > 0 for 30 min → warn | sendmail log → metric |

### API tier (API Gateway + Lambda)

| Signal      | Metric                                                          | Starting threshold          | Source                  |
| ----------- | --------------------------------------------------------------- | --------------------------- | ----------------------- |
| Latency     | Lambda duration p95, per function                               | > 3 s for 10 min → warn     | `cloudwatch_exporter`   |
| Latency     | End-to-end `/list` round trip from Kuma                         | > 5 s for 10 min → warn     | Kuma                    |
| Traffic     | Requests/min per route                                          | — (dashboard)               | API Gateway / CW        |
| Errors      | 5xx rate per route                                              | > 5%/10 min → critical      | `cloudwatch_exporter`   |
| Errors      | Lambda invocation errors / throttles                            | any throttles in 5 min → warn | `cloudwatch_exporter` |
| Errors      | Cognito post-confirmation trigger errors                        | any in 15 min → warn        | `cloudwatch_exporter`   |
| Saturation  | Lambda concurrency used / account limit                         | > 70% for 10 min → warn     | `cloudwatch_exporter`   |
| Saturation  | API Gateway integration latency tail                            | p99 > 10 s → warn           | `cloudwatch_exporter`   |

### Frontend (CloudFront + S3 + React app)

| Signal      | Metric                                                          | Starting threshold          | Source                 |
| ----------- | --------------------------------------------------------------- | --------------------------- | ---------------------- |
| Latency     | CloudFront origin latency p95                                   | > 1 s for 15 min → warn     | `cloudwatch_exporter`  |
| Latency     | Kuma HTTP probe to `https://<control>/`                         | > 3 s for 10 min → warn     | Kuma                   |
| Traffic     | Requests/min, unique viewers (daily)                            | — (dashboard)               | `cloudwatch_exporter`  |
| Errors      | CloudFront 5xx rate                                             | > 1%/15 min → warn          | `cloudwatch_exporter`  |
| Errors      | CloudFront 4xx rate (spike only)                                | 3× baseline for 15 min → warn | `cloudwatch_exporter`|
| Errors      | ACM cert expiry                                                 | < 21 days → warn, < 7 days → crit | `cloudwatch_exporter` / Kuma |
| Saturation  | S3 bucket size, request rate                                    | — (dashboard)               | `cloudwatch_exporter`  |

### Data tier (DynamoDB + EFS)

| Signal      | Metric                                                          | Starting threshold          | Source                 |
| ----------- | --------------------------------------------------------------- | --------------------------- | ---------------------- |
| Latency     | DynamoDB `SuccessfulRequestLatency` p95 per operation           | > 100 ms for 15 min → warn  | `cloudwatch_exporter`  |
| Latency     | EFS `PercentIOLimit`                                            | > 80% for 15 min → warn     | `cloudwatch_exporter`  |
| Traffic     | DynamoDB consumed RCU/WCU, EFS ClientConnections                | — (dashboard)               | `cloudwatch_exporter`  |
| Errors      | DynamoDB throttled requests                                     | any in 5 min → warn         | `cloudwatch_exporter`  |
| Errors      | DynamoDB system errors                                          | any in 5 min → critical     | `cloudwatch_exporter`  |
| Saturation  | EFS BurstCreditBalance                                          | < 20% for 1 h → warn        | `cloudwatch_exporter`  |
| Saturation  | DynamoDB capacity used / provisioned (on-demand: account limit) | > 70% for 15 min → warn     | `cloudwatch_exporter`  |

### Auth tier (Cognito)

| Signal      | Metric                                                          | Starting threshold          | Source                 |
| ----------- | --------------------------------------------------------------- | --------------------------- | ---------------------- |
| Latency     | Post-confirmation trigger duration                              | p95 > 5 s for 10 min → warn | `cloudwatch_exporter`  |
| Traffic     | Sign-ins/min, sign-ups/day                                      | — (dashboard)               | `cloudwatch_exporter`  |
| Errors      | Sign-in failures (throttling, auth)                             | > 30%/15 min → warn         | `cloudwatch_exporter`  |
| Errors      | `assign_osid` / post-confirmation Lambda errors                 | any in 15 min → critical    | `cloudwatch_exporter`  |
| Saturation  | Cognito API throttling events                                   | any in 15 min → warn        | `cloudwatch_exporter`  |

### Platform (ECS cluster, NAT, VPC)

| Signal      | Metric                                                          | Starting threshold          | Source                 |
| ----------- | --------------------------------------------------------------- | --------------------------- | ---------------------- |
| Latency     | ECS task start time p95                                         | > 60 s → warn               | `cloudwatch_exporter`  |
| Traffic     | NAT `BytesOutToDestination`, cluster-wide network in/out        | — (dashboard)               | `node_exporter` / CW   |
| Errors      | ECS task exit (non-zero) count                                  | > 3 in 1 h per service → critical | `cloudwatch_exporter` |
| Errors      | Container restart loop (same task ID)                           | > 3 restarts in 1 h → critical | `cloudwatch_exporter`|
| Saturation  | EC2 host CPU / memory / disk per cluster instance               | > 85% for 15 min → warn     | `node_exporter`        |
| Saturation  | ECS cluster reservation (CPU/mem)                               | > 80% for 15 min → warn     | `cloudwatch_exporter`  |
| Saturation  | NAT instance bandwidth                                          | > 80% of instance cap for 15 min → warn | `node_exporter` |

### Tuning discipline

- Every threshold above ships with an issue-tracker label; after each alert fires, the runbook instructs the responder to confirm whether the threshold was correct, too sensitive, or too loose, and record the answer on the issue.
- Thresholds are code (Prometheus rules, Kuma IaC in Phase 4) — changes go through the normal PR review. No tuning via web UI.
- Monthly during 0.7.0, review the top three noisiest and the top three longest-silent alerts. Tighten or drop accordingly. The goal for the release is not maximum coverage; it is **zero false pages in a typical week**.

---

## Phase 1: Alert Sink + ntfy + Uptime Monitoring

### 1. Alert sink Lambda

A single Lambda (`alert_sink`) accepts a webhook payload and fans out to Pushover and/or ntfy. Becomes the universal alerting endpoint for every monitoring component added in later phases.

**`lambda/api/alert_sink/`** — new function (formerly `alert_sms`):
- Behind a Lambda Function URL (not API Gateway — Kuma's webhook provider posts directly).
- Authenticates callers by shared secret in the `X-Alert-Secret` header (read from SSM at cold start; validated with `hmac.compare_digest`).
- Accepts `{ "summary": "...", "severity": "critical|warning|info", "source": "..." }`.
- Fan-out per the severity table in [Alert transports](#alert-transports): critical → Pushover priority 1 + ntfy priority 5; warning → ntfy priority 3; info → drop.
- Outbound calls go over plain HTTPS (`urllib.request`) — no boto3 SNS/SES dependencies.
- Returns `204` on success.

The Pushover application token and user key, and the ntfy publisher token, all live in SSM Parameter Store (`SecureString`) and are read at cold start.

### 2. Self-hosted ntfy deployment

Run [ntfy](https://ntfy.sh) as a fourth ECS service (alongside the three mail tiers).

**`docker/ntfy/`** — thin `Dockerfile` over `binwiederhier/ntfy`, exposing port 80 for the HTTP API. No TLS termination in the container (ALB handles that).

**`terraform/infra/modules/monitoring/ntfy.tf`**:
- `aws_ecs_task_definition` with one container. Config via `NTFY_*` env vars (no YAML file). Key settings: `NTFY_BASE_URL=https://ntfy.<control-domain>`, `NTFY_LISTEN_HTTP=:80`, `NTFY_CACHE_FILE=/var/cache/ntfy/cache.db`, `NTFY_AUTH_FILE=/var/cache/ntfy/user.db`, `NTFY_AUTH_DEFAULT_ACCESS=deny-all`, `NTFY_BEHIND_PROXY=true`.
- EFS access point at `/ntfy` for `/var/cache/ntfy` (message cache + auth DB survive task replacement).
- `aws_ecs_service` with `desired_count = 1`.
- Target group on the existing Kuma ALB, selected by **host-header listener rule** `ntfy.<control-domain>` (default rule still forwards to Kuma with Cognito auth). The ntfy rule has no authenticate-cognito action — ntfy enforces its own token auth.
- Route 53 A record `ntfy.<control-domain>` pointing at the same ALB.
- A dedicated security group; egress open, ingress only from the ALB SG on port 80.

**First-boot bootstrap (manual, via ECS Exec):**
1. `ntfy user add --role=admin admin` — prompts for a password. Store in password manager.
2. `ntfy token add admin` — returns a publisher token. Store in SSM as `/cabal/ntfy_publisher_token` (SecureString).
3. `ntfy access admin '*' rw` — admin gets full access (default for `role=admin`, no-op but explicit).
4. On the user's phone: install the ntfy app, add `https://ntfy.<control-domain>` as a server, log in with `admin` + password, subscribe to the `alerts` topic.

Phase 4 replaces this with declarative user/ACL provisioning via a small bootstrap Lambda.

### 3. Uptime Kuma deployment

Run [Uptime Kuma](https://github.com/louislam/uptime-kuma) as a fifth ECS service.

**`docker/uptime-kuma/`** — `Dockerfile` based on the upstream `louislam/uptime-kuma` image. TLS cert wiring is not needed; the ALB fronts the UI.

**`terraform/infra/modules/monitoring/kuma.tf`**:
- `aws_ecs_task_definition` with one container, EFS volume mount for `/app/data` (Kuma's SQLite store) so state survives task replacement.
- `aws_ecs_service` with `desired_count = 1`, placed on the same cluster as the mail tiers.
- ALB target group; the listener's **default action** (authenticate-cognito + forward) points here.
- Route 53 record `uptime.<control-domain>` (same ALB as ntfy).
- Webhook notification provider configured in Kuma to POST to the `alert_sink` Lambda URL.

### 4. Initial monitor set

Configured in Kuma at first boot (manually for Phase 1; Phase 4 considers IaC for Kuma config):

| Monitor                          | Type           | Severity |
| -------------------------------- | -------------- | -------- |
| IMAP TLS handshake (port 993)    | TCP + cert     | critical |
| SMTP relay (port 25)             | TCP            | critical |
| Submission TLS (port 587 + 465)  | TCP + cert     | critical |
| `https://<control>/` (React app) | HTTP 200       | critical |
| API Gateway `/list` round-trip   | HTTP, auth'd   | critical |
| ntfy server probe                | HTTP 200 on `https://ntfy.<control-domain>/v1/health` | critical |
| Control-domain ACM cert          | cert expiry    | warning  |

### 5. Acceptance for Phase 1

- A deliberately broken health check (e.g., temporarily blocking port 993 in a security group on the dev account) produces a Pushover push **and** an ntfy push within 2 minutes.
- Resolution sends a "recovered" push (ntfy only — recoveries are `info`-severity in Kuma and we may promote them to `warning` in the Lambda formatter; tune during Phase 1 based on feel).
- Kuma UI is reachable behind Cognito at `uptime.<control-domain>`.
- ntfy UI/app is reachable (with token auth) at `ntfy.<control-domain>`.

---

## Phase 2: Heartbeat Monitoring

### 1. Self-hosted Healthchecks

Run [Healthchecks](https://github.com/healthchecks/healthchecks) (Django app) as a fifth ECS service.

**`docker/healthchecks/`** — `Dockerfile` from upstream `healthchecks/healthchecks` plus an entrypoint that pulls `SECRET_KEY`, `DB_*`, and SMTP credentials from SSM.

**`terraform/infra/modules/monitoring/healthchecks.tf`**:
- ECS task definition + service.
- SQLite on EFS for Phase 2 (avoid standing up RDS just for this; revisit if write volume becomes a problem).
- ALB target group + listener rule on `heartbeat.<control-domain>`, Cognito authorizer.
- Webhook integration pointed at the `alert_sink` Lambda.

### 2. Instrument scheduled jobs

Each scheduled component pings a unique URL on success. A missing ping past the grace period fires an alert.

| Job                                  | Where to add the ping                                            | Schedule          |
| ------------------------------------ | ---------------------------------------------------------------- | ----------------- |
| Certbot renewal Lambda               | End of `lambda/certbot-renewal/function.py`                      | Daily             |
| Weekly Terraform `apply`             | End of `.github/workflows/terraform.yml` (Wednesday job)         | Weekly            |
| DynamoDB / EFS AWS Backup            | EventBridge rule → tiny Lambda that pings on `BACKUP_JOB` success | Daily             |
| DMARC report ingestion               | End of `process_dmarc` Lambda                                    | Hourly            |
| ECS reconfigure (`reconfigure.sh`)   | Successful end of each loop iteration                            | On SQS message    |
| Cognito user-sync Lambda             | End of function                                                  | On invocation     |

Ping URLs are stored as SSM parameters per job; Lambdas read at cold start.

### 3. Acceptance for Phase 2

- Disabling the certbot renewal schedule in dev produces a heartbeat-missed push notification within the configured grace window.
- Healthchecks dashboard shows green for every registered job in steady state.

---

## Phase 3: Metrics Stack

### 1. Prometheus + Alertmanager + Grafana

Three new ECS services. Choose VictoriaMetrics over upstream Prometheus if Phase 1/2 experience suggests memory pressure on the cluster; the rest of the stack is unchanged.

**`docker/prometheus/`**, **`docker/alertmanager/`**, **`docker/grafana/`** — Dockerfiles thinly wrapping the upstream images, entrypoint pulls config from SSM.

**`terraform/infra/modules/monitoring/metrics.tf`**:
- One ECS service per component, all in a private subnet.
- EFS-mounted volumes for Prometheus TSDB, Alertmanager state, Grafana SQLite.
- ALB rule on `metrics.<control-domain>` → Grafana, Cognito-authorized.
- Prometheus and Alertmanager are not exposed externally; reached via Grafana's data-source proxy and internal DNS.

### 2. Exporters

Add as **sidecars** in existing ECS task definitions (no new EC2 footprint):

| Tier             | Exporter(s)                                                                         |
| ---------------- | ----------------------------------------------------------------------------------- |
| `imap`           | `node_exporter`, `dovecot_exporter`                                                 |
| `smtp-in`        | `node_exporter`, `postfix_exporter` (works against sendmail logs with config tweak) |
| `smtp-out`       | `node_exporter`, `postfix_exporter`, `opendkim_exporter` (or scrape statsfile)      |
| Cluster (one)    | `cloudwatch_exporter` — pulls Lambda errors/duration, ALB 5xx, DynamoDB throttles, EFS BurstCreditBalance, NAT bytes |
| Cluster (one)    | `blackbox_exporter` — duplicates Kuma's TCP/HTTP probes for graphing + multi-condition alerts |

Service discovery uses the existing ECS Service Connect / DNS, scraped on a private port.

### 3. Initial alert rules (`prometheus/rules/`)

Tuned for low noise — the goal is not to recreate Kuma's alerts but to add multi-condition alerts that black-box can't express:

- **`MailQueueGrowing`**: sendmail queue depth > 50 for 15 min — warning.
- **`MailDeliveryFailureRate`**: outbound 5xx rate > 5% over 30 min — critical.
- **`Lambda5xxSpike`**: any API Gateway integration > 5% 5xx over 10 min — critical.
- **`EFSBurstCreditsLow`**: BurstCreditBalance < 20% for 1 h — warning.
- **`DynamoDBThrottling`**: any throttled requests in 5 min — warning.
- **`ContainerRestartLoop`**: ECS task restarted > 3 times in 1 h — critical.
- **`CertExpiringSoon`**: any cert < 21 days from expiry — warning (redundant with Kuma but Prom can group + escalate).

Alertmanager routes critical → `alert_sink` Lambda (Pushover + ntfy), warning → `alert_sink` Lambda (ntfy only), both → Grafana annotation.

### 4. Acceptance for Phase 3

- Grafana dashboards exist for: Mail Tiers, AWS Services, API Gateway, Frontend.
- Each rule above has been triggered at least once on the dev account (synthetically or by load) and produced the expected Pushover and/or ntfy notification.
- Alertmanager is configured with at least one silence window (e.g., the weekly Wednesday Terraform apply) to validate silencing works.

---

## Phase 4: Logs + Tuning

### 1. Loki + Promtail (or stay on CloudWatch Logs)

Default to **staying on CloudWatch Logs** unless Phase 3 reveals a need (cost, search latency, cross-tier correlation). If we add Loki:

**`docker/loki/`**, **`docker/promtail/`** — Promtail runs as a sidecar in each mail-tier task, ships supervisord/sendmail/dovecot logs to Loki. Loki runs as one ECS service, EFS-backed for chunks. Grafana gets Loki as a data source for unified logs+metrics views.

### 2. Log-derived metrics & alerts

Whether on CloudWatch (metric filters) or Loki (`logfmt` + `count_over_time`), add:

- Sendmail "deferred" / "bounced" rate.
- fail2ban ban events (visibility, not alerting).
- IMAP authentication failure rate (potential brute-force signal).
- Cognito post-confirmation trigger errors.

### 3. IaC for Kuma + Healthchecks config

Both tools support config-as-code via API. Add a `terraform/infra/modules/monitoring/config/` submodule (or a small bootstrap Lambda) that idempotently reconciles monitor and check definitions from a YAML file in the repo. This eliminates the "Phase 1 manual setup" footgun.

### 4. Runbooks

For each alert defined in Phases 1–3, a short runbook in `docs/operations/runbooks/`:
- What the alert means.
- Who/what is impacted.
- First three things to check.
- Escalation path.

Alertmanager and Kuma both support a `runbook_url` field — populate it.

### 5. Acceptance for Phase 4

- Every alert that can fire a push notification has a linked runbook.
- A quarterly "monitoring review" task is scheduled (Healthchecks) that prompts a human to confirm dashboards, silences, and on-call numbers are still correct.
- Tabletop exercise: simulate three failure modes (mail queue backup, IMAP cert expiry, certbot Lambda silently disabled) and confirm each produces the expected alert with a runbook link.

---

## Cross-cutting concerns

### Cost

All components run on the existing ECS cluster. Expected new spend: incremental EC2 capacity for the monitoring services (likely one extra `t3.small`-sized worker), EFS storage for state (negligible). Pushover is a one-time $5 per mobile platform. ntfy is self-hosted — no per-message cost. No managed-service costs beyond what's already present.

### Secrets

Every shared secret (Lambda webhook token, Grafana admin password, Healthchecks `SECRET_KEY`) lives in SSM Parameter Store with `SecureString` type, scoped IAM access, and a documented rotation procedure. No secrets in Terraform state or environment variables in plain task definitions.

### Authentication

Every UI (Kuma, Healthchecks, Grafana) sits behind the existing Cognito authorizer at the ALB layer. No public dashboards.

### Disaster recovery

Monitoring state on EFS is included in the existing AWS Backup plan (extend the `backup` module's selection). Loss of the monitoring stack must not block recovery of mail — verify by running a test where the `monitoring` module is destroyed and re-applied; mail tiers must remain unaffected throughout.

### Out of scope for 0.7.0

- Distributed tracing (Tempo / OpenTelemetry).
- APM for the React app (Sentry self-hosted is plausible but defers to a later release).
- PagerDuty-style on-call rotation (single on-call for now; Pushover + ntfy to one device is sufficient).
