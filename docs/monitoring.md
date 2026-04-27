# Monitoring & Alerting

The 0.7.0 release adds an optional monitoring stack on top of the existing mail infrastructure. Phase 1 provides black-box uptime monitoring plus a push-notification alerting path that bypasses the Cabalmail email system. Phase 2 adds heartbeat monitoring for scheduled jobs (certbot, weekly Terraform, AWS Backup, DMARC ingestion, ECS reconfigure loop, Cognito user-sync). See [monitoring-plan.md](./0.7.0/monitoring-plan.md) for the multi-phase roadmap and design rationale; this page is the operator's runbook for enabling the stack and completing first-boot configuration.

The stack is disabled by default. When enabled it deploys:

- **Uptime Kuma** — a small, self-hosted status-page / probe runner. Reachable at `https://uptime.<control-domain>/` behind Cognito login.
- **Self-hosted ntfy** — open-source push-notification server. Reachable at `https://ntfy.<control-domain>/` with token auth enforced by the app (not the ALB).
- **`alert_sink` Lambda** — a webhook sink fronted by a Lambda Function URL. Callers authenticate with a shared secret. `critical` severity fans out to Pushover (priority 1) and ntfy (priority 5); `warning` goes to ntfy (priority 3); `info` is dropped.
- **Self-hosted Healthchecks** (Phase 2) — a [healthchecks.io](https://healthchecks.io) instance for "did this scheduled job ping recently?" heartbeats. Reachable at `https://heartbeat.<control-domain>/` behind Cognito.
- **`backup_heartbeat` Lambda** (Phase 2) — invoked by an EventBridge rule on AWS Backup `JOB_COMPLETED` events; pings the corresponding Healthchecks check.

## 1. Create your Pushover account and application

Pushover is the "wake someone up" channel — priority-1 pushes bypass Do Not Disturb on iOS and Android. It is paid: **$5 one-time per mobile platform** you intend to receive alerts on, after a 30-day trial.

1. Go to <https://pushover.net/signup> and create an account. Verify your email.
2. Install the Pushover app from the App Store / Play Store and log in. After login you'll see your **user key** on the app's home screen and on <https://pushover.net>.
3. On the Pushover site, open **Your Applications → Create an Application/API Token**. Name it `cabalmail-alerts`, type `Application`. Accept the terms. You'll get an **API Token/Key**.
4. Save both values somewhere temporarily (password manager). You'll put them into SSM in step 5.

## 2. Enable the flag per environment

The monitoring stack is gated by `var.monitoring`. Set it to `true` only in the environments where you want it on (prod always; stage/dev only while actively testing).

In your GitHub repository settings, go to **Settings → Environments → _environment_ → Variables** and add:

| Variable                                  | Example value | Notes                                                                                                                    |
| ----------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `TF_VAR_MONITORING`                       | `true`        | Gates the whole stack. Set to `true` in `prod`; leave as `false` (or unset) elsewhere.                                   |
| `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN`   | `false`       | Phase 2 only. Controls whether the Healthchecks signup form accepts new accounts. Defaults to `false` (closed) when unset; flip to `true` for the bootstrap signup in §11, then back to `false`. Has no effect when `TF_VAR_MONITORING=false`. |

## 3. Apply Terraform

Kick off the "Build and Deploy Terraform Infrastructure" workflow (same process as in [setup.md §Provisioning](./setup.md)). The apply will create:

- `cabal-uptime-kuma` and `cabal-ntfy` ECR repositories (always, regardless of the flag).
- SSM `SecureString` parameters: `/cabal/alert_sink_secret` (auto-generated random), `/cabal/pushover_user_key`, `/cabal/pushover_app_token`, `/cabal/ntfy_publisher_token` (all with `ignore_changes` so manual values stick).
- `alert_sink` Lambda with a Function URL.
- Uptime Kuma and ntfy ECS services, both EFS-backed.
- Public ALB with:
  - Default rule → Kuma, fronted by Cognito.
  - Host-header rule on `ntfy.<control-domain>` → ntfy (no ALB auth).
- Route 53 records `uptime.<control-domain>` and `ntfy.<control-domain>`.

Note the Terraform outputs — you will need `alert_sink_function_url` and `ntfy_service_name` below.

## 4. Seed the Pushover SSM parameters

```
aws ssm put-parameter --name /cabal/pushover_user_key  --type SecureString --overwrite --value '<user-key-from-step-1>'
aws ssm put-parameter --name /cabal/pushover_app_token --type SecureString --overwrite --value '<app-token-from-step-1>'
```

Terraform won't touch these on subsequent applies (`ignore_changes = [value]`).

## 5. Bootstrap the ntfy admin user and publisher token

ntfy ships with `NTFY_AUTH_DEFAULT_ACCESS=deny-all`; nobody can read or write until you create an admin. Do it once via ECS Exec.

1. Find the ntfy task ARN:
   ```
   CLUSTER=<cluster-name>
   TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name cabal-ntfy --query 'taskArns[0]' --output text)
   ```
2. Open a shell in the container:
   ```
   aws ecs execute-command --cluster "$CLUSTER" --task "$TASK" --container ntfy --interactive --command "/bin/sh"
   ```
3. Inside the container, create the admin user. You'll be prompted for a password — **store it in your password manager**, you'll need it on the phone.
   ```
   ntfy user add --role=admin admin
   ```
4. Generate a bearer token for the Lambda:
   ```
   ntfy token add admin
   ```
   Copy the `tk_...` token it prints.
5. Exit the container. Store the token in SSM:
   ```
   aws ssm put-parameter --name /cabal/ntfy_publisher_token --type SecureString --overwrite --value 'tk_...'
   ```

The Lambda caches secrets at cold start, so the next push after the secret-set triggers a re-fetch automatically.

## 6. Subscribe your phone to ntfy

1. Install the ntfy app from the App Store / Play Store.
2. In the app, **Settings → Users** (or similar), add a user for `https://ntfy.<control-domain>` with username `admin` and the password from step 5.
3. Tap **Subscribe to topic** → server `https://ntfy.<control-domain>`, topic `alerts`. The app shows 0 messages until the first alert fires.

## 7. First-boot configuration in Uptime Kuma

Uptime Kuma ships without any admin user; the first person to hit the UI creates one.

1. Open `https://uptime.<control-domain>/` in a browser. You will be redirected to the Cognito hosted UI to sign in.
2. After the Cognito handshake you land on Kuma's setup page. Create the admin account. **Store the password in your password manager** — Kuma does not use Cognito for its own identity; it has a separate local user.

## 8. Wire the Kuma webhook notification provider

In Kuma, add a new Notification provider:

- **Type**: Webhook
- **Post URL**: value of the `alert_sink_function_url` Terraform output (the Lambda Function URL, e.g. `https://abc123.lambda-url.us-west-1.on.aws/`).
- **Request body**: *JSON (content-type: application/json)*
- **Custom headers**:
  ```
  X-Alert-Secret: <paste from /cabal/alert_sink_secret>
  ```
  Retrieve the secret with:
  ```
  aws ssm get-parameter --name /cabal/alert_sink_secret --with-decryption --query Parameter.Value --output text
  ```
- **Body template**:
  {% raw %}
  ```json
  {
    "summary": "{{ msg }}",
    "severity": "{% if heartbeatJSON.status == 0 %}critical{% else %}info{% endif %}",
    "source": "kuma/{{ monitorJSON.name }}"
  }
  ```
  {% endraw %}

  Kuma uses Liquid templating — {% raw %}`{{ ... }}`{% endraw %} for interpolation, {% raw %}`{% if %}…{% endif %}`{% endraw %} for conditionals. Handlebars-style {% raw %}`{{#if}}`{% endraw %} will fail with a TokenizationError.

Click **Test** — you should receive a Pushover push **and** a ntfy notification within 30 seconds. If either is missing, check the `alert_sink` CloudWatch log group at `/cabal/lambda/alert_sink` for per-transport errors.

## 9. Create the Phase 1 monitor set

In the Kuma dashboard, add one monitor for each row below. Attach the webhook notification to every monitor.

| Monitor                        | Type        | Target                                     | Interval | Retries |
| ------------------------------ | ----------- | ------------------------------------------ | -------- | ------- |
| IMAP TLS handshake             | TCP port    | `imap.<control-domain>:993`                | 60 s     | 2       |
| SMTP relay (STARTTLS)          | TCP port    | `smtp-in.<control-domain>:25`              | 60 s     | 2       |
| Submission (STARTTLS)          | TCP port    | `smtp-out.<control-domain>:587`            | 60 s     | 2       |
| Submission (implicit TLS)      | TCP port    | `smtp-out.<control-domain>:465`            | 60 s     | 2       |
| Admin app                      | HTTP(s)     | `https://admin.<control-domain>/`          | 120 s    | 2       |
| API round-trip (`/list`)       | HTTP(s)     | `https://admin.<control-domain>/prod/list` | 5 min    | 2       |
| ntfy server health             | HTTP(s)     | `https://ntfy.<control-domain>/v1/health`  | 120 s    | 2       |
| Control-domain cert            | Keyword     | `https://admin.<control-domain>/`, keyword: any. Enable **Certificate expiration notification**: 21 / 7 / 1 days. | 4 h | 2 |

The `/list` probe needs a valid Cognito JWT. In Phase 1, seed it manually: sign in to the admin app, copy your `id_token` out of DevTools, and paste it as `Authorization: Bearer <token>` in the monitor's headers. Rotate it monthly. (Phase 4 adds a longer-lived monitor identity.)

## 10. Acceptance checklist

- [ ] `https://uptime.<control-domain>/` is unreachable without a Cognito session.
- [ ] `https://ntfy.<control-domain>/alerts` returns `401` without a bearer token.
- [ ] Temporarily blocking port 993 in the dev account (security group or `fail2ban` rule) produces a Pushover push **and** a ntfy push within ~2 minutes.
- [ ] Unblocking it produces a recovery push.
- [ ] Every Phase 1 monitor shows green in the Kuma dashboard.

## Secret rotation

To rotate the webhook shared secret:

1. Generate a new value: `openssl rand -base64 36 | tr -d '='`.
2. Put it into SSM: `aws ssm put-parameter --name /cabal/alert_sink_secret --type SecureString --overwrite --value '<new-value>'`.
3. Update the `X-Alert-Secret` header on every Kuma webhook provider.
4. Trigger a test notification from Kuma to confirm.

To rotate the ntfy publisher token: run `ntfy token del <old-token>` and `ntfy token add admin` inside the container, then update `/cabal/ntfy_publisher_token`.

To rotate the Pushover app token: create a new application on pushover.net, update `/cabal/pushover_app_token`, delete the old application.

The Terraform `ignore_changes = [value]` lifecycle on each SSM parameter means subsequent `terraform apply` runs will not revert your rotated value.

## Disabling the stack

Set `TF_VAR_MONITORING=false` in the GitHub environment and re-run Terraform. The module is gated with `count = var.monitoring ? 1 : 0`, so the ECS services, ALB, Lambda, and SSM parameters are destroyed cleanly. The `cabal-uptime-kuma`, `cabal-ntfy`, and `cabal-healthchecks` ECR repositories and the Cognito user pool domain persist (they are cheap and not flag-gated).

**Note on EFS state:** destroying the stack leaves the `/uptime-kuma`, `/ntfy`, and `/healthchecks` directories on the shared EFS. Re-enabling monitoring later will pick up the existing SQLite databases and ntfy user/auth state, preserving your configuration. Remove the directories manually from any running mail-tier container if you want a clean start.

---

# Phase 2: Heartbeat monitoring

Phase 2 adds Healthchecks for the scheduled jobs that Phase 1 cannot see (cron-style runs, EventBridge schedules, the ECS reconfigure loop). It is enabled by the same `TF_VAR_MONITORING=true` flag — there is no separate switch. Once Phase 1 is up, follow the steps below to bring Phase 2 online.

## 11. First-boot configuration in Healthchecks

`https://heartbeat.<control-domain>/` sits behind Cognito. The Cabalmail Cognito user pool is the front door; Healthchecks itself uses its own local accounts (Cognito gates whether you can _reach_ the UI, Healthchecks gates whether you can _change_ checks).

The Healthchecks task is wired to deliver mail through the IMAP tier's local-delivery sendmail (`EMAIL_HOST=imap.cabal.internal`, port 25, no TLS, no auth) — see [healthchecks.tf](../terraform/infra/modules/monitoring/healthchecks.tf). This means magic-link signup and password reset work natively, **as long as you sign up with a Cabalmail-hosted address whose mailbox you can read**. Mail destined for non-Cabalmail addresses (gmail, etc.) won't deliver from this Healthchecks instance — it can only relay inbound to itself.

1. Open the signup form: in your GitHub environment for this stack, set `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN=true` and re-run the Terraform workflow. The default is `false` (closed); flipping to `true` lets the Healthchecks `Sign Up` form accept new accounts.
2. Pick a Cabalmail address you own to use as the operator login (e.g. `admin@<one-of-your-mail-domains>`). It needs to be a real address in `cabal-addresses`; if it isn't, IMAP's sendmail will TEMPFAIL the magic-link delivery.
3. Open `https://heartbeat.<control-domain>/` in a browser. Cognito challenges you. Sign in.
4. On the Healthchecks landing page, click **Sign Up** and enter the address from step 2. Healthchecks emails a magic link; the link arrives in your Cabalmail inbox within seconds. Click it to set a password.
5. Lock the door: set `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN=false` (or just delete the variable — `false` is the default) and re-run Terraform.

**Fallback if mail delivery doesn't work** (e.g. you want to bootstrap before adding a Cabalmail address, or the IMAP tier is down): create a superuser via ECS Exec and log in with the password form:

```
aws ecs execute-command --cluster <cluster> \
  --task $(aws ecs list-tasks --cluster <cluster> --service-name cabal-healthchecks --query 'taskArns[0]' --output text) \
  --container healthchecks --interactive --command /bin/sh
# inside the container:
cd /opt/healthchecks
./manage.py shell -c "from django.contrib.auth.models import User; User.objects.filter(email='you@example.com').delete()"
./manage.py createsuperuser
```

Then log in at `https://heartbeat.<control-domain>/accounts/login/` using the password field (next to the magic-link button).

## 12. Create one check per scheduled job

In the Healthchecks dashboard, click **Add Check** for each entry below. The **schedule** column tells Healthchecks what cadence to expect; tune the **grace** column if it produces false alarms.

| Check name             | Schedule type / value          | Grace | Notes                                                          |
| ---------------------- | ------------------------------ | ----- | -------------------------------------------------------------- |
| `certbot-renewal`      | Simple, every 60 days          | 24 h  | Lambda runs every 60 days via EventBridge Scheduler.           |
| `aws-backup`           | Simple, every 1 day            | 6 h   | EventBridge `JOB_COMPLETED` events feed `backup_heartbeat`.    |
| `dmarc-ingest`         | Simple, every 6 hours          | 2 h   | DMARC scheduler runs every 6 h.                                |
| `ecs-reconfigure`      | Simple, every 30 minutes       | 30 m  | Pings on each successful regenerate; fallback fires every 15 m.|
| `cognito-user-sync`    | Simple, every 30 days          | 7 d   | Fires only on user signup; very loose grace by design.         |
| `quarterly-review`     | Simple, every 90 days          | 14 d  | Phase 4 §5. Manual operator ping after the quarterly review (see below).|

(The Phase 2 plan originally included a `terraform-weekly` heartbeat. That was dropped because the Terraform workflow no longer runs on a cron schedule, so a heartbeat that only fires on manual dispatch isn't a useful signal.)

For each check, copy the **ping URL** (e.g. `https://heartbeat.<control-domain>/ping/abcd1234-...`) and paste it into the matching SSM parameter:

```
aws ssm put-parameter --name /cabal/healthcheck_ping_certbot_renewal     --type SecureString --overwrite --value '<url>'
aws ssm put-parameter --name /cabal/healthcheck_ping_aws_backup          --type SecureString --overwrite --value '<url>'
aws ssm put-parameter --name /cabal/healthcheck_ping_dmarc_ingest        --type SecureString --overwrite --value '<url>'
aws ssm put-parameter --name /cabal/healthcheck_ping_ecs_reconfigure     --type SecureString --overwrite --value '<url>'
aws ssm put-parameter --name /cabal/healthcheck_ping_cognito_user_sync   --type SecureString --overwrite --value '<url>'
aws ssm put-parameter --name /cabal/healthcheck_ping_quarterly_review    --type SecureString --overwrite --value '<url>'
```

Lambdas cache the URL at cold start, so the next invocation after the secret-set picks it up automatically. The mail-tier containers receive the URL via ECS task-definition `secrets` and need a deployment cycle (`aws ecs update-service --force-new-deployment`) to pick up changes.

## 13. Wire Healthchecks alerts back to `alert_sink`

A missed heartbeat is only useful if it becomes a push notification. In Healthchecks, **Integrations → Add Integration → Webhook**:

- **URL for "down" events** — the same `alert_sink_function_url` from Phase 1.
- **HTTP Method** — `POST`.
- **HTTP Headers**:
  ```
  Content-Type: application/json
  X-Alert-Secret: <value of /cabal/alert_sink_secret>
  ```
- **Request Body**:
  ```json
  {"summary": "Missed heartbeat: $NAME", "severity": "critical", "source": "healthchecks/$NAME"}
  ```
- **URL for "up" events** — same URL.
- **Body for "up" events**:
  ```json
  {"summary": "Recovered: $NAME", "severity": "warning", "source": "healthchecks/$NAME"}
  ```

Then assign the integration to every check from step 12.

## 14. Acceptance checklist for Phase 2

- [ ] `https://heartbeat.<control-domain>/` is unreachable without a Cognito session.
- [ ] Every check from step 12 shows green in the Healthchecks dashboard within one full schedule cycle (i.e. the certbot check stays "new" until either you trigger the Lambda manually or wait 60 days; the others should turn green within 24 hours).
- [ ] Disabling the certbot Lambda's EventBridge schedule in dev (or temporarily setting its ping SSM parameter to `placeholder-`) and waiting past the grace window produces a Pushover push and a ntfy push citing `healthchecks/certbot-renewal`.
- [ ] Manually triggering the certbot Lambda (`aws lambda invoke --function-name cabal-certbot-renewal /tmp/out.json`) restores the check to green within one cold-start.
- [ ] Triggering `aws backup start-backup-job` (or waiting for the daily run) advances the `aws-backup` check.

## Disabling individual heartbeats

To silence one heartbeat without disabling the entire monitoring stack: pause the corresponding check in the Healthchecks UI, or set its SSM parameter back to a value that does not start with `http` (e.g. `aws ssm put-parameter --overwrite --type SecureString --name /cabal/healthcheck_ping_dmarc_ingest --value 'paused'`). Consumer code skips the ping when the value is not an HTTP(S) URL, and Healthchecks stops expecting pings while the check is paused.

## Phase 2 troubleshooting

- **Healthchecks task fails with `CannotCreateContainerError: failed to chown … operation not permitted`.** Same family as the Kuma `chown` issue from Phase 1 lesson 2 in [monitoring-plan.md §6](./0.7.0/monitoring-plan.md), but the chown is happening in dockerd at container creation, not in an entrypoint shim. The upstream Dockerfile runs `useradd --system hc` (system uid, typically ~999) and `mkdir /data && chown hc /data`, so when ECS bind-mounts the EFS access point onto `/data`, dockerd's copy-up logic tries to chown the host volume path to hc's uid — which the access point's `posix_user = 1000:1000` enforcement refuses. [healthchecks.tf](../terraform/infra/modules/monitoring/healthchecks.tf) sidesteps this by mounting EFS at `/var/local/healthchecks-data` (a path that doesn't exist in the image, so no copy-up runs) and forcing the container to run as `user = "1000:1000"` so writes succeed under the access point's translated uid. If you change the data path, update the `DB_NAME` env var and the `mountPoints.containerPath` in lockstep.
- **Healthchecks dashboard shows `heartbeat.<control-domain>` but Cognito redirects loop.** The ALB SG already has `alb_https_out` from Phase 1 (Cognito token exchange). If the loop is on first signup specifically, the signup form is closed: set `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN=true` in your GitHub environment and re-run Terraform, complete the signup, then flip the variable back to `false`.
- **Heartbeat misfires immediately after enabling monitoring.** Each consumer caches the SSM ping URL at cold start (Lambdas) or task start (containers). After populating a placeholder, force a refresh: `aws lambda invoke --function-name cabal-certbot-renewal /tmp/out.json` for Lambdas; `aws ecs update-service --cluster <cluster> --service cabal-imap --force-new-deployment` (and the smtp tiers) for the reconfigure heartbeat.
- **`backup_heartbeat` Lambda silent.** Confirm `var.backup = true` in the environment — without the AWS Backup plan, no `Backup Job State Change` events fire and the EventBridge rule has nothing to invoke. The Lambda existing without the backup plan is harmless but useless.
- **Healthchecks task is up and serving but the ALB target stays unhealthy.** Look at the uwsgi log: if `GET /` from the VPC subnet IPs returns HTTP 400 in single-digit ms, Django is rejecting the probe with `DisallowedHost`. ALB target-group health checks can't set a custom Host header — they send `Host: <target-ip>:<port>`, which fails Django's `ALLOWED_HOSTS` check. The task definition uses `ALLOWED_HOSTS=*` for this reason; the ALB listener rule for `heartbeat.<control-domain>` is the only public path to the target group, and the task SG only accepts traffic from the ALB SG, so hostname validation is enforced at the ALB layer. If you change `ALLOWED_HOSTS` away from `*` you also need to either accept the 4xx in the matcher (don't) or front the health check with something that can rewrite the Host header (don't).

---

# Phase 3: Metrics stack

Phase 3 adds a Prometheus / Alertmanager / Grafana stack and a small set of cluster-scope exporters. Like Phases 1 and 2, it's gated by `TF_VAR_MONITORING=true` — there is no separate switch.

When enabled the apply adds:

- **Prometheus** — TSDB on EFS at `/prometheus`. Not exposed publicly; reach via Grafana's data-source proxy or `aws ecs execute-command` port-forwarding.
- **Alertmanager** — silences and notification log on EFS at `/alertmanager`. Not exposed publicly. Posts to the `alert_sink` Lambda for both critical and warning severities.
- **Grafana** — UI on EFS at `/grafana` (sqlite). Reachable at `https://metrics.<control-domain>/` behind Cognito. Cognito-authenticated users land as anonymous Viewers; admin actions (data sources, dashboards beyond what's provisioned) require the local admin password from `/cabal/grafana_admin_password`.
- **`cloudwatch_exporter`** — single ECS service translating AWS/Lambda, AWS/DynamoDB, AWS/EFS, AWS/ECS, AWS/ApiGateway, AWS/ApplicationELB, AWS/CertificateManager, and AWS/Cognito metrics for Prometheus.
- **`blackbox_exporter`** — single ECS service for synthetic HTTP/TCP/TLS probes (mail tier ports + the React app).
- **`node_exporter`** — DaemonSet ECS service (one task per cluster instance), bind-mounting host `/proc` and `/sys` to report host CPU/memory/disk per EC2.
- **Cloud Map private DNS namespace `cabal-monitoring.cabal.internal`** — Prometheus uses this to discover scrape targets.
- A new ALB listener rule on `metrics.<control-domain>` with its own Cognito client (priority 120, after Phase 1's ntfy=100 / heartbeat=110).

## 15. Bake images and apply

Prometheus, Alertmanager, Grafana, and the three exporters all ship as their own ECR images built by the existing Docker workflow. The first time you toggle `TF_VAR_MONITORING=true` after the Phase 3 PR lands, run the **Build and Push Container Images** workflow first — this populates the new ECR repos with `sha-<first-8>` tags. Then run the Terraform workflow, which will pick the freshly-pushed tag from `/cabal/deployed_image_tag` and create the new ECS services.

If you flip `TF_VAR_MONITORING` to `true` without the images present, ECS will keep the services in pending state until the images appear; nothing else breaks.

## 16. Set the Grafana admin password (optional)

Terraform auto-generates a random Grafana admin password on first apply (`/cabal/grafana_admin_password`, `ignore_changes` so subsequent applies don't rotate it). Read it with:

```
aws ssm get-parameter --name /cabal/grafana_admin_password --with-decryption --query Parameter.Value --output text
```

Or set your own:

```
aws ssm put-parameter --name /cabal/grafana_admin_password --type SecureString --overwrite --value '<your-password>'
```

Grafana picks up the value at task start (`GF_SECURITY_ADMIN_PASSWORD`); a `force-new-deployment` rolls in any change.

## 17. First-boot configuration in Grafana

1. Open `https://metrics.<control-domain>/`. Cognito challenges; sign in.
2. You arrive as an anonymous Viewer. Navigate to **Cabalmail → Dashboards** in the side menu — four provisioned dashboards (`Mail Tiers`, `AWS Services`, `API Gateway & Lambda`, `Frontend`) are already there. Initial charts will be empty for ~5 min until cloudwatch_exporter has scraped.
3. To make changes — add a panel, edit a datasource, install a plugin — sign in to the local admin account at `/login`. The username is `admin`; the password is the SSM value from §16.
4. The Prometheus datasource is provisioned read-only at `http://prometheus.cabal-monitoring.cabal.internal:9090`. To verify, **Connections → Data sources → Prometheus → Test**.

## 18. Verify Prometheus scrape targets

Prometheus has no public UI by default. To inspect scrape state:

```
CLUSTER=<cluster-name>
TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name cabal-prometheus --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster "$CLUSTER" --task "$TASK" --container prometheus --interactive --command "/bin/sh"
# inside the container:
wget -qO- http://localhost:9090/api/v1/targets | head
```

Every target listed in `prometheus.yml` should be `health: up`. Targets to expect: 1× prometheus self-scrape, 1× alertmanager, 1× cloudwatch-exporter, 4× blackbox probes (HTTP + 3× TCP), 1+× node-exporter (one per cluster EC2 in the daemon).

## 19. Acceptance checklist for Phase 3

- [ ] `https://metrics.<control-domain>/` is unreachable without a Cognito session.
- [ ] All four provisioned dashboards exist under the **Cabalmail** folder in Grafana.
- [ ] `cloudwatch_exporter` scrape target shows `up` in Prometheus.
- [ ] `node_exporter` shows one target per cluster EC2 instance.
- [ ] `blackbox_exporter` HTTP probe to `https://<control-domain>/` is `up`.
- [ ] Synthetic alert: tighten one warning rule (e.g. `EFSBurstCreditsLow` to `< 100e9`) in `docker/prometheus/rules/alerts.yml`, rebuild + redeploy, and confirm the Alertmanager → `alert_sink` chain produces a ntfy push within ~5 min.
- [ ] Add a one-hour silence in Alertmanager (UI is at port 9093 inside the cluster; reach via Grafana's Alertmanager data source — currently configured pointing at the cluster-internal URL — or ECS Exec port-forwarding) and confirm the silence suppresses the alert.

## Phase 3 — deferred items

The §3 plan calls for two mail-tier-specific alert rules (`MailQueueGrowing`, `MailDeliveryFailureRate`) and four sidecar exporters (`node_exporter` per tier, `dovecot_exporter`, `postfix_exporter`, `opendkim_exporter`). These are **deliberately not part of Phase 3** for two reasons:

- `postfix_exporter` parses Postfix log lines; Cabalmail uses Sendmail with a different log format. Making `postfix_exporter` work usefully against `/var/log/maillog` needs a per-line adapter or a fork. That design pass is more naturally addressed alongside Phase 4 log aggregation, where a Loki+LogQL approach can replace the exporter entirely.
- The plan framed `node_exporter` as a per-tier sidecar in each of the three mail-tier task definitions. We deviated and made it a single DAEMON-strategy ECS service so each EC2 host reports one set of host metrics rather than three duplicates. This produces cleaner dashboards and avoids changing the mail-tier task definitions (a destructive operation — see [monitoring-plan.md §6](./0.7.0/monitoring-plan.md) on stable-flag discipline for sidecars).

The mail-tier alert rules will land in a follow-up pass that ships either log-derived metrics or per-tier sidecars, after the trade-off is settled.

## What populates when

Some Grafana panels are blank for several minutes after the stack starts; some are blank by design. Useful expectations to set before you go diagnostic-hunting:

- **1–2 min: probe panels** (Mail Tiers TCP/TLS, Frontend HTTP probe). Blackbox-driven; Prometheus scrapes blackbox every 30s.
- **3–5 min: AWS-side metrics that always have a value** (EFS BurstCreditBalance / PercentIOLimit, ECS RunningTaskCount, ACM days to expiry). cloudwatch_exporter polls every 60s with a built-in 120s `delay_seconds` lag (CloudWatch metrics aren't immediately consistent), so first datapoint arrives ~3 min after the exporter starts.
- **Empty until something happens (correct behavior)**: DynamoDB ThrottledRequests, Lambda errors / throttles, API Gateway 5xx rate. These are alert signals; flat-empty in steady state is what you want.
- **Empty unless someone is using the system**: DynamoDB ConsumedRead/Write CU, API Gateway request count, Lambda duration p95. Use the admin app once and these populate within the next minute.
- **Permanently empty with the current config**: CloudFront panels on the Frontend dashboard. CloudFront metrics live exclusively in `us-east-1`, and a single cloudwatch_exporter task scrapes one region. Either enable the AWS/CloudFront block in [docker/cloudwatch-exporter/config.yml](../docker/cloudwatch-exporter/config.yml) and run a second exporter pinned to `us-east-1`, or strip the panels — Phase 1's Kuma already covers the React app end-to-end so they're nice-to-have rather than load-bearing.

If a panel is still blank after ~10 min and isn't in one of the categories above, dig in — start with `wget -qO- http://localhost:9090/api/v1/label/__name__/values` from inside the Prometheus task to confirm whether the metric series even exists.

## Phase 3 troubleshooting

The notes below are lessons from the actual deploy, in roughly the order they were tripped over. Each is also reflected in code on `0.7.0`; this list is for future readers and re-deployers.

- **Cloud Map service replacement cycle.** Every `terraform apply` was scheduling a forced replacement of all five awsvpc-mode Cloud Map services and the destroy step was failing with `ResourceInUse: Service contains registered instances`. Operators were having to manually `aws servicediscovery deregister-instance` after each apply. Root cause: AWS deprecated the `failure_threshold` field on `health_check_custom_config` and pins it to `1` server-side regardless. An empty `health_check_custom_config {}` block reads back as drift on every plan. Fix in [terraform/infra/modules/monitoring/discovery.tf](../terraform/infra/modules/monitoring/discovery.tf) is to set `failure_threshold = 1` explicitly and add `lifecycle { ignore_changes = [health_check_custom_config] }`. With that fix in place, manual deregistration should never be needed.
- **node_exporter ECS service rejected with `containerName/containerPort must be specified`.** The DAEMON service uses `network_mode = "host"`. With awsvpc, ECS infers the ENI mapping from the task definition; with host or bridge, `service_registries.container_name` and `container_port` must be explicit.
- **node_exporter ECS service rejected with `serviceRegistries value is configured to use a type 'A' DNS record, which is not supported when specifying 'host' or 'bridge' for networkMode`.** A host can run multiple containers on different ports, so ECS can't infer the port from an A-record alone. node_exporter's Cloud Map service registers SRV records instead; the awsvpc-mode services keep type A. Prometheus's scrape config follows: `type: SRV` on the `node` job, `type: A` everywhere else.
- **node_exporter ECS service rejected with `Specifying a capacity provider strategy is not supported when you create a service using the DAEMON scheduling strategy`.** DAEMON places exactly one task per container instance regardless of which capacity provider supplied it; AWS rejects any `capacity_provider_strategy` block, even an inherited cluster default. Use `launch_type = "EC2"` instead.
- **Grafana task fails to start with `failed to chown /var/lib/ecs/volumes/...: operation not permitted`.** Same family as the Phase 1 Kuma chown gotcha. The upstream `grafana/grafana` image creates `/var/lib/grafana` with explicit ownership, so binding an EFS access point at that path makes dockerd's copy-up try to chown the host volume mount and the access point's `posix_user` rejects it. Fix mirrors Phase 2 Healthchecks: mount EFS at a path that doesn't exist in the image (`/grafana-data`) and override `GF_PATHS_DATA` to match, so dockerd has nothing to copy-up. The same fix will apply to any future upstream image that pre-creates its data directory.
- **cloudwatch_exporter container exits immediately with the JVM logging `NumberFormatException`.** The Java cloudwatch_exporter takes its config path positionally (`<port> <config-path>`); the `--config.file=` flag is a Go/Prometheus convention. The flag was being parsed as the listen port and the JVM crashed at startup. The Dockerfile `CMD` now passes `/config/config.yml` directly.
- **Grafana comes up but the four bootstrap dashboards don't appear under the Cabalmail folder.** Two distinct problems hit at once. First: the provisioned Prometheus datasource didn't pin a `uid`, so Grafana auto-generated one — and the dashboards reference `datasource.uid: "prometheus"`, so the binding silently failed. Second: Grafana 11.x silently rejects provisioned dashboard JSON without a top-level `"id": null` field. Both fixes shipped together in [docker/grafana/provisioning/datasources/prometheus.yml](../docker/grafana/provisioning/datasources/prometheus.yml) and the dashboard JSONs.
- **Alertmanager's webhook calls fail with `403 Forbidden` from the `alert_sink` Lambda.** The Lambda accepts both `X-Alert-Secret: <secret>` and `Authorization: Bearer <secret>`. Alertmanager's `http_config.authorization` sets the Bearer header; if the header arrives with leading whitespace or the secret in the wrong env var, the HMAC compare fails. Check `/cabal/lambda/alert_sink` log group and confirm the SSM secret matches what the entrypoint substituted into `/etc/alertmanager-rendered/alertmanager.yml`.
- **Prometheus reports `cloudwatch-exporter` target as `down`.** Most likely a stale image tag (the JVM crash above). After ruling that out, check the IAM task role policy `cabal-cloudwatch-exporter-task-policy` includes `cloudwatch:GetMetricData`, `cloudwatch:GetMetricStatistics`, and `cloudwatch:ListMetrics` on `Resource: "*"`. Region-mismatched metric scrapes fail silently — the exporter doesn't error, it just returns no data; confirm `AWS_REGION` env var on the task matches the region of the metrics you're scraping.
- **`node_exporter` daemon tasks don't start.** The daemon-strategy service requires the ECS cluster instance role to allow daemon-strategy task placement (the existing `AmazonEC2ContainerServiceforEC2Role` covers this) and for the host's SG to allow inbound TCP 9100 from the Prometheus task SG. The mail-tier `aws_security_group.ecs_instance` already permits all VPC traffic; if you ever scope it down, add an explicit ingress rule for 9100 from the Prometheus SG.
- **Grafana "Data source is failing" against Prometheus, but Prometheus is healthy from Exec.** The Grafana SG allows broad egress; the Prometheus SG only allows ingress on 9090 from Grafana's SG (intentional — Prometheus has no public surface). If you switched the Grafana SG mid-apply, the security group rule may not have been recreated. `aws ecs update-service --cluster <cluster> --service cabal-grafana --force-new-deployment` to roll the task and re-resolve.
- **Grafana dashboards still empty after the provisioning fixes above.** Three remaining causes, in order of likelihood: cloudwatch_exporter has not yet scraped (give it 10 min after first start; see "What populates when"); region mismatch on the cloudwatch_exporter task; the metric panel queries reference statistics not enabled in [docker/cloudwatch-exporter/config.yml](../docker/cloudwatch-exporter/config.yml) (e.g. asking for `p99` when only `Average` is exported). Check Prometheus `/api/v1/label/__name__/values` for the `aws_*` series the dashboard expects.

---

# Phase 4: Logs, runbooks, and tuning

Phase 4 doesn't add new ECS services in its first wave — instead it formalizes the pieces of an alerting system that often get neglected: a runbook for every alert, a tap-action link from the push notification straight to that runbook, an explicit "stay on CloudWatch Logs" decision, and a quarterly-review heartbeat that prompts the operator to keep all of the above honest.

Like Phases 1-3, Phase 4 is gated by `TF_VAR_MONITORING=true` — there is no separate flag.

## 20. Runbook framework

Every alert that can fire a push notification has a runbook in [docs/operations/runbooks/](./operations/runbooks/). Each runbook follows the same shape: what the alert means, who/what is impacted, the first three things to check, and how to escalate. See [the runbook README](./operations/runbooks/README.md) for the full index.

How the runbook URL reaches your phone:

- **Prometheus / Alertmanager**: each rule in [docker/prometheus/rules/alerts.yml](../docker/prometheus/rules/alerts.yml) carries a `runbook_url` annotation. Alertmanager forwards it as part of its native webhook body; the `alert_sink` Lambda's translator surfaces it (`_translate_alertmanager`) and attaches it to outbound pushes.
- **Kuma & Healthchecks**: their webhook bodies don't carry a per-monitor runbook URL natively. The `alert_sink` Lambda has a static `_RUNBOOK_MAP` keyed by `source` (e.g. `kuma/IMAP TLS handshake`, `healthchecks/certbot-renewal`). When you add or rename a Kuma monitor, update the keys in [`lambda/api/alert_sink/function.py`](../lambda/api/alert_sink/function.py) to match, or the push will arrive without a runbook link.

When a push includes a runbook URL, you'll see:

- **Pushover**: a "Runbook" tap-action link in the notification, below the body.
- **ntfy**: the notification body itself becomes tappable (`Click` header), opening the runbook in the phone's browser.

The map and the runbook files are version-controlled together; PRs that change one without the other should fail review.

## 21. Logs: stay on CloudWatch (for now)

The Phase 4 plan offered a choice between adding self-hosted Loki+Promtail and staying on CloudWatch Logs. Cabalmail stays on CloudWatch:

- Log volume is small (one operator, low mail traffic). CloudWatch's per-GB ingest cost dominates the comparison and is not a problem at this scale.
- We don't need cross-tier log correlation in real time. Each tier's logs are already grouped (`/ecs/cabal-imap`, `/aws/lambda/cabal-list`, etc.); a CloudWatch Logs Insights query covers the rare ad-hoc cross-tier search.
- Loki adds another stateful ECS service to operate, with EFS-backed chunk storage that grows monotonically. The maintenance cost outweighs the benefit until either log volume or cross-tier search frequency becomes painful.
- Log-derived metrics (sendmail deferred/bounced rate, IMAP auth failure rate, fail2ban activity, Cognito post-confirmation errors) are doable as **CloudWatch metric filters** without a log-aggregation tier. They show up as Prometheus metrics via `cloudwatch_exporter` and reuse the existing alert path.

Revisit if log volume grows past ~10 GB/day, if a recurring incident type needs cross-tier search, or if a feature needs structured query (Phase 4 §2 metrics will surface what we can get without it).

## 22. Quarterly monitoring review

The system needs maintenance attention. The plan's "tuning discipline" (zero false pages in a typical week, threshold tuning recorded against issues, monthly review of the noisiest and longest-silent alerts) only works if it actually happens. Phase 4 §5 adds a `quarterly-review` Healthchecks check that pages the operator if 90+ days pass without a manual ping.

The check is **not** automated. Nothing pings it on a schedule. The operator pings it after walking through the checklist in [heartbeat-quarterly-review.md](./operations/runbooks/heartbeat-quarterly-review.md).

Set up the check the same way as the other heartbeats in §12, then ping it once at the end of setup (so it starts green, with a 90-day clock):

```sh
PING_URL=$(aws ssm get-parameter --name /cabal/healthcheck_ping_quarterly_review --with-decryption --query Parameter.Value --output text)
curl -fsS "$PING_URL"
```

The runbook covers what the review entails. If you skip it, the worst that happens is one critical-severity push every 90 + 14 = 104 days.

## 23. Tabletop exercises

Phase 4 §5 acceptance includes simulating three failure modes end-to-end:

| Scenario | How to simulate | Expected page | Expected runbook |
| --- | --- | --- | --- |
| Mail queue backup | On `smtp-out`, `mailq` and `sendmail -OQueueLA=0 -q` to artificially defer; the rule fires once Phase 4 §2 log-derived metrics land. *Until then, the closest equivalent is a Kuma probe failure on port 25 by blocking it in the SG.* | Probe failure → critical ntfy + Pushover | [probe-failure.md](./operations/runbooks/probe-failure.md) |
| IMAP cert expiring (control-domain) | In dev: re-issue a short-lived cert and wait, or temporarily replace the listener cert with a deliberately near-expiry one. Don't do this in prod. | `BlackboxTLSCertExpiringSoon` (warning ntfy) and Kuma's "Control-domain cert" 21-day notification | [cert-expiring.md](./operations/runbooks/cert-expiring.md) |
| Certbot Lambda silently disabled | Disable the EventBridge schedule on `cabal-certbot-renewal` in dev; wait past the 24 h grace | `healthchecks/certbot-renewal` missed → critical ntfy + Pushover | [heartbeat-certbot-renewal.md](./operations/runbooks/heartbeat-certbot-renewal.md) |

Run the table top once after each Phase 4 ship, and again at every quarterly review. If the expected push doesn't arrive, fix the broken link before treating the tabletop as passing.

## 24. Acceptance for Phase 4

- [ ] Every alert in `docker/prometheus/rules/alerts.yml` has a `runbook_url` annotation pointing into [docs/operations/runbooks/](./operations/runbooks/).
- [ ] The `alert_sink` Lambda's `_RUNBOOK_MAP` covers every Kuma monitor in §9 and every Healthchecks check in §12.
- [ ] A test push from Kuma (any monitor) and from Healthchecks (any check) arrives on the operator's phone with a tappable runbook link.
- [ ] An Alertmanager test alert (e.g. via `amtool alert add testing severity=warning runbook_url=https://example.test/r.md ...`) round-trips with the runbook URL preserved.
- [ ] The `quarterly-review` check is configured in Healthchecks and shows green after the initial bootstrap ping.
- [ ] Tabletop exercise from §23 runs cleanly for at least the certbot scenario; mail-queue and cert-expiry scenarios run cleanly once Phase 4 §2 lands.

## 25. Phase 4 §2 — log-derived metrics & alerts

The Phase 4 plan calls out four log-derived metrics — sendmail deferred, sendmail bounced, IMAP auth failures, and Cognito post-confirmation errors. The first three ship as **CloudWatch metric filters** in [terraform/infra/modules/monitoring/log_metrics.tf](../terraform/infra/modules/monitoring/log_metrics.tf); the Cognito case is folded into the existing `LambdaErrors` alert by extending its function-name regex.

| Filter | Log group(s) | Pattern | Metric (in `Cabalmail/Logs`) |
| --- | --- | --- | --- |
| `cabal-sendmail-deferred-{tier}` | `/ecs/cabal-imap`, `/ecs/cabal-smtp-in`, `/ecs/cabal-smtp-out` | `"stat=Deferred"` | `SendmailDeferred` |
| `cabal-sendmail-bounced-{tier}` | same three | `"dsn=5"` | `SendmailBounced` |
| `cabal-imap-auth-failures` | `/ecs/cabal-imap` | `"imap-login" "auth failed"` | `IMAPAuthFailures` |

All metrics emit value=1 per matching log line, default 0. CloudWatch aggregates per-minute. cloudwatch_exporter scrapes the `Sum` statistic and exposes `aws_cabalmail_logs_<metric>_sum` to Prometheus.

The Prometheus alert rules in the new `log-derived` group of [docker/prometheus/rules/alerts.yml](../docker/prometheus/rules/alerts.yml) start at:

| Alert | Threshold | Severity | Runbook |
| --- | --- | --- | --- |
| `SendmailDeferredSpike` | >10 deferreds/10 min, sustained 15 min | warning | [sendmail-deferred-spike.md](./operations/runbooks/sendmail-deferred-spike.md) |
| `SendmailBouncedSpike` | >15 bounces/30 min, sustained 15 min | critical | [sendmail-bounced-spike.md](./operations/runbooks/sendmail-bounced-spike.md) |
| `IMAPAuthFailureSpike` | >25 auth-fails/5 min, sustained 5 min | warning | [imap-auth-failure-spike.md](./operations/runbooks/imap-auth-failure-spike.md) |

These thresholds are starting points. Expect them to move once we see what real traffic looks like; record the rationale in the alert's GitHub issue per the [tuning discipline](./0.7.0/monitoring-plan.md#tuning-discipline).

### What's deferred

- **fail2ban metrics**: `[program:fail2ban]` is currently commented out in every mail-tier `supervisord.conf`. A metric filter today would publish flat-zero forever and mask the disabled state. Add the filter when fail2ban is re-enabled. The [imap-auth-failure-spike runbook](./operations/runbooks/imap-auth-failure-spike.md) calls out the absence of fail2ban as the reason this alert is the only signal for brute-force activity.
- **Cognito post-confirmation log-derived metric**: rolled into `LambdaErrors` instead. The existing `function_name=~"cabal-.+"` regex is extended to `cabal-.+|assign_osid` so the post-confirmation Lambda's invocation errors fire the existing alert. A separate log-filter approach was rejected to avoid adopting the Lambda-auto-created `/aws/lambda/assign_osid` log group (which would force a `terraform import` on existing stacks).

### Acceptance for Phase 4 §2

- [ ] After applying Terraform with `var.monitoring=true`, `aws logs describe-metric-filters --log-group-name /ecs/cabal-imap` lists three Cabalmail filters.
- [ ] cloudwatch_exporter exposes `aws_cabalmail_logs_sendmail_deferred_sum`, `aws_cabalmail_logs_sendmail_bounced_sum`, `aws_cabalmail_logs_imap_auth_failures_sum` in Prometheus (`http://localhost:9090/api/v1/label/__name__/values` from inside the Prometheus task).
- [ ] Synthetic test: log a fake `stat=Deferred` line into `/ecs/cabal-imap` (e.g. via `aws ecs execute-command` and `logger -t sm-mta`) 12 times in 1 minute and confirm `SendmailDeferredSpike` fires within ~17 min (10 min window + 15 min `for` clause).
- [ ] `LambdaErrors` rule with the extended regex catches an injected error in the `assign_osid` Lambda (e.g. by temporarily raising in the function and triggering a sign-up).

## 26. Phase 4 §3 — IaC for Healthchecks (and the deferral of Kuma IaC)

The Phase 4 plan called for declarative IaC over both Kuma monitors and Healthchecks checks. This release ships **Healthchecks only**, via a small reconciler Lambda. Kuma stays manual.

### 26.1 Healthchecks IaC

The `cabal-healthchecks-iac` Lambda reads desired state from [`lambda/api/healthchecks_iac/config.py`](../lambda/api/healthchecks_iac/config.py) and reconciles against the running Healthchecks instance. On each invocation it:

1. Lists existing checks via the v3 API.
2. Upserts each entry in `config.py` using `unique=["name"]` so existing-by-name updates rather than duplicates.
3. Pulls each check's ping URL from the API response and writes it to the corresponding `/cabal/healthcheck_ping_*` SSM parameter (only if the value differs — no churn).
4. Logs a warning for any check present in Healthchecks but absent from `config.py`. Does **not** auto-delete; deliberate operator action via the UI is required to drop a check.

The Lambda runs in private subnets and reaches Healthchecks via a Cloud Map A record (`healthchecks.cabal-monitoring.cabal.internal:8000`), bypassing the Cognito-fronted ALB. The v3 API key is sufficient auth and lives in `/cabal/healthchecks_api_key` (SSM `SecureString`).

The Terraform `aws_lambda_invocation` resource re-fires whenever the Lambda's `source_code_hash` changes — i.e. when `config.py` is edited and the build pipeline pushes a new zip. So a typical workflow for adding a new check is:

1. Edit `lambda/api/healthchecks_iac/config.py` — add an entry.
2. *Optional but recommended*: add a matching SSM parameter in [`monitoring/ssm.tf`](../terraform/infra/modules/monitoring/ssm.tf) `local.heartbeat_jobs` and reference it from the consumer (Lambda env var, ECS secrets, etc.).
3. Open a PR. CI runs `lambda_api_python.yml` (rebuilds the zip), then `terraform.yml` (applies → invokes the Lambda).
4. Confirm the new check appears in the Healthchecks dashboard.

### 26.2 One-time bootstrap

Before the first reconciliation can happen, the operator must:

1. **Create the API key** in the Healthchecks UI: log in (Cognito → Healthchecks magic-link), open Project Settings → API Access, create a read+write key, copy the value. The v3 API has no endpoint to create keys, so this stays manual.
2. **Seed SSM**:
   ```sh
   aws ssm put-parameter --name /cabal/healthchecks_api_key --type SecureString --overwrite --value '<key-from-step-1>'
   ```
3. **Force a reconcile** (the Lambda's auto-invocation already ran with the placeholder and returned `skipped`; manually trigger it now that the key is real):
   ```sh
   aws lambda invoke --function-name cabal-healthchecks-iac /tmp/out.json && cat /tmp/out.json
   ```
   Expected response: `{"status":"ok","reconciled":6,"failed":0,"extras":[],"checks":[...]}`.
4. **Wire up notifications**: see [§13](#13-wire-healthchecks-alerts-back-to-alert_sink). Integrations are still manually managed — assign the existing Webhook integration to every check after first reconcile. (The v3 API doesn't expose channel CRUD.)

After bootstrap, ongoing changes follow the §26.1 workflow with no manual steps.

### 26.3 Why Kuma IaC is deferred

Kuma exposes only a Socket.IO API in the version we pin. There is no first-class REST API for monitor CRUD; the unofficial `uptime-kuma-api` Python library uses an internal Socket.IO message format that has shifted between Kuma minor versions. Building reconciliation around it would couple our Terraform apply path to Kuma's UI implementation details — a maintenance liability for the eight Phase 1 monitors we'd be managing.

The trade-off:

- **Pro of Kuma IaC**: parity with Healthchecks; no Phase 1 setup footgun for Kuma.
- **Con of Kuma IaC**: pinned to `uptime-kuma-api`'s upstream cadence; breaks on Kuma upgrades; the alternative (custom Socket.IO client) is more code than the eight monitors are worth.

Decision: keep Kuma manual. Mitigations:
- The Phase 1 monitor table in [§9](#9-create-the-phase-1-monitor-set) is explicit and copy-paste-ready.
- The [§22 quarterly review](#22-quarterly-monitoring-review) prompts an operator pass over Kuma config every 90 days — drift gets caught.
- The `_RUNBOOK_MAP` in [`alert_sink/function.py`](../lambda/api/alert_sink/function.py) is keyed on Kuma's monitor names; renaming a monitor without updating the map silently drops the runbook link, which is recoverable.

Revisit when Kuma ships a stable REST API (tracked in [louislam/uptime-kuma#1170](https://github.com/louislam/uptime-kuma/issues/1170)).

### 26.4 Acceptance for Phase 4 §3

- [ ] After applying Terraform with the API key seeded, `aws lambda invoke --function-name cabal-healthchecks-iac /tmp/out.json` returns `status: ok` with `reconciled = 6`.
- [ ] All six checks visible in Healthchecks UI under the operator's project.
- [ ] All six `/cabal/healthcheck_ping_*` SSM parameters are populated with `https://heartbeat.<control-domain>/ping/...` URLs (not placeholders).
- [ ] Editing `config.py` (e.g. adjusting a grace period), re-running the build pipeline, and applying Terraform causes a re-invocation — confirm via `aws logs tail /cabal/lambda/healthchecks_iac --since 5m`.
- [ ] Bootstrap-ahead test: with the API key still placeholder, the Lambda's first invocation returns `status: skipped` (and Terraform apply succeeds anyway).
